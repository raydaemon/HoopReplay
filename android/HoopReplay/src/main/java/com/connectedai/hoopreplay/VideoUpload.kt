package com.connectedai.hoopreplay

import android.content.Context
import android.net.Uri
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URI
import java.nio.ByteBuffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** When whole-game recordings upload to the cloud for cloud highlight cutting (Settings → Upload recordings). */
enum class UploadRecordings(val label: String) { Off("Off"), WifiOnly("Wi-Fi only"), Always("Always") }

/**
 * Highlight and footage uploads to Cloudflare R2 through the Web API (spec:
 * docs/superpowers/specs/2026-10-04-video-highlights-design.md). The phone never holds R2
 * credentials: every PUT goes to a presigned URL the API hands out after checking access.
 */
object VideoUpload {
    private const val PREFS = "hoop_video_upload"

    fun uploadRecordings(context: Context): UploadRecordings =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("upload_recordings", null)
            ?.let { name -> UploadRecordings.entries.firstOrNull { it.name == name } } ?: UploadRecordings.WifiOnly

    fun setUploadRecordings(context: Context, value: UploadRecordings) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("upload_recordings", value.name).apply()

    /** The game's cloud uuid after making sure the game and its events are synced. */
    private suspend fun syncedGameUuid(context: Context, db: HoopDb, gameId: Long): String {
        HoopSync.push(context, db)
        return HoopSync.gameUuid(context, gameId) ?: error(t("Sync this game before uploading"))
    }

    /** Uploads a finished phone highlight so the Web game page can play it. */
    suspend fun uploadHighlight(context: Context, db: HoopDb, gameId: Long, result: HighlightResult, targetKey: String, label: String) = withContext(Dispatchers.IO) {
        val uuid = syncedGameUuid(context, db, gameId)
        val start = JSONObject(HoopSync.webRequest(context, "POST", "/api/highlights/upload", JSONObject().put("game_uuid", uuid)))
        put(start.getString("put_url"), result.file.length()) { out -> result.file.inputStream().use { it.copyTo(out) } }
        HoopSync.webRequest(context, "PUT", "/api/highlights/upload", JSONObject()
            .put("game_uuid", uuid).put("id", start.getString("id")).put("target_key", targetKey).put("target_label", label)
            .put("duration_ms", result.durationMs).put("clip_count", result.clips))
        Unit
    }

    /** Recording upload state for the game: (uploaded, total) over the recordings this phone holds. */
    suspend fun footageStatus(context: Context, db: HoopDb, gameId: Long): Pair<Int, Int> = withContext(Dispatchers.IO) {
        val local = db.segments(gameId).filter { it.sequence > 0 && it.uri.isNotBlank() }
        val uuid = HoopSync.gameUuid(context, gameId) ?: return@withContext 0 to local.size
        val uploaded = uploadedSequences(context, uuid)
        local.count { it.sequence in uploaded } to local.size
    }

    private fun uploadedSequences(context: Context, uuid: String): Set<Int> {
        val rows = JSONArray(HoopSync.webRequest(context, "GET", "/api/footage?game_uuid=$uuid"))
        return (0 until rows.length()).map { rows.getJSONObject(it) }.filter { it.optString("upload_status") == "uploaded" }.map { it.getInt("sequence") }.toSet()
    }

    /**
     * Uploads every recording of the game that is on this phone and not in the cloud yet, as
     * resumable multipart uploads: the upload id is kept until the recording completes, so a
     * killed app or a lost connection continues where it stopped. [onProgress] gets bytes sent / total.
     */
    suspend fun uploadFootage(context: Context, db: HoopDb, gameId: Long, onProgress: (Long, Long) -> Unit = { _, _ -> }) = withContext(Dispatchers.IO) {
        val uuid = syncedGameUuid(context, db, gameId)
        val uploaded = uploadedSequences(context, uuid)
        val pending = db.segments(gameId).filter { it.sequence > 0 && it.uri.isNotBlank() && it.sequence !in uploaded }
            .mapNotNull { seg -> val uri = Uri.parse(seg.uri); size(context, uri)?.let { Triple(seg, uri, it) } }
        val total = pending.sumOf { it.third }
        var sent = 0L
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for ((seg, uri, size) in pending) {
            val key = "upload_${uuid}_${seg.sequence}"
            val start = JSONObject(HoopSync.webRequest(context, "POST", "/api/footage", JSONObject()
                .put("game_uuid", uuid).put("sequence", seg.sequence).put("size", size).put("upload_id", prefs.getString(key, ""))))
            val uploadId = start.getString("upload_id")
            prefs.edit().putString(key, uploadId).apply()
            val partSize = start.getLong("part_size")
            val etags = mutableMapOf<Int, String>()
            start.getJSONArray("done").let { done -> for (i in 0 until done.length()) done.getJSONObject(i).let { etags[it.getInt("number")] = it.getString("etag") } }
            sent += etags.keys.sumOf { minOf(partSize, size - (it - 1) * partSize) }
            onProgress(sent, total)
            val parts = start.getJSONArray("parts")
            for (i in 0 until parts.length()) {
                val part = parts.getJSONObject(i)
                val number = part.getInt("number")
                val offset = (number - 1) * partSize
                val length = minOf(partSize, size - offset)
                val bytes = readRange(context, uri, offset, length.toInt())
                etags[number] = put(part.getString("url"), length) { it.write(bytes) }
                sent += length
                onProgress(sent, total)
            }
            HoopSync.webRequest(context, "PUT", "/api/footage", JSONObject().put("game_uuid", uuid).put("sequence", seg.sequence).put("upload_id", uploadId)
                .put("parts", JSONArray(etags.map { (n, e) -> JSONObject().put("number", n).put("etag", e) })))
            prefs.edit().remove(key).apply()
        }
    }

    /** Queues a background footage upload of the game, honouring the Upload recordings setting. */
    fun schedule(context: Context, gameId: Long) {
        val network = when (uploadRecordings(context)) {
            UploadRecordings.Off -> return
            UploadRecordings.WifiOnly -> NetworkType.UNMETERED
            UploadRecordings.Always -> NetworkType.CONNECTED
        }
        if (!HoopSync.isSignedIn(context)) return
        val request = OneTimeWorkRequestBuilder<FootageUploadWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(network).build())
            .setInputData(workDataOf("game_id" to gameId))
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork("footage-$gameId", ExistingWorkPolicy.REPLACE, request)
    }

    private fun size(context: Context, uri: Uri): Long? =
        runCatching { context.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize.takeIf { s -> s > 0 } } }.getOrNull()

    private fun readRange(context: Context, uri: Uri, offset: Long, length: Int): ByteArray =
        context.contentResolver.openFileDescriptor(uri, "r")!!.use { fd ->
            FileInputStream(fd.fileDescriptor).channel.use { channel ->
                val buffer = ByteBuffer.allocate(length)
                channel.position(offset)
                while (buffer.hasRemaining() && channel.read(buffer) >= 0) Unit
                buffer.array()
            }
        }

    /** PUTs [length] bytes to a presigned R2 URL and returns the ETag R2 assigned. */
    private fun put(url: String, length: Long, write: (java.io.OutputStream) -> Unit): String {
        val connection = (URI(url).toURL().openConnection() as HttpURLConnection).apply {
            requestMethod = "PUT"
            doOutput = true
            connectTimeout = 15_000
            readTimeout = 120_000
            setRequestProperty("Content-Type", "video/mp4")
            setFixedLengthStreamingMode(length)
        }
        connection.outputStream.use(write)
        val code = connection.responseCode
        val etag = connection.getHeaderField("ETag").orEmpty()
        val error = if (code in 200..299) "" else connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
        connection.disconnect()
        check(code in 200..299) { t("Upload failed ({code}): {text}", "code" to code, "text" to error.take(200)) }
        return etag
    }
}

/**
 * Uploads one game's recordings in the background. Android stops a worker after about ten
 * minutes; it then asks to be retried and the next run resumes the multipart upload.
 */
// ponytail: no foreground service, so a multi-GB game takes several worker runs; add setForeground() with a notification if users wait too long.
class FootageUploadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val gameId = inputData.getLong("game_id", -1).takeIf { it > 0 } ?: return Result.failure()
        return runCatching { VideoUpload.uploadFootage(applicationContext, HoopDb(applicationContext), gameId) }
            .fold({ Result.success() }, { if (runAttemptCount < 20) Result.retry() else Result.failure() })
    }
}
