package com.connectedai.hoopreplay

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import androidx.media3.common.MediaItem
import androidx.media3.effect.Presentation
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.Effects
import androidx.media3.transformer.VideoEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One recording file of a game: its sequence, device-local uri, and length. */
data class VideoSegment(val sequence: Int, val uri: String, val durationMs: Long)

/** Who a highlight is for: one player's plays, or one team's scoring plays. */
sealed interface HighlightTarget {
    data class PlayerTarget(val playerId: Long) : HighlightTarget
    data class TeamTarget(val teamId: Long) : HighlightTarget
}

/** A stretch of one recording, [startMs, endMs) inside segment `segment`. */
data class Clip(val segment: Int, val startMs: Long, val endMs: Long)

private const val CLIP_BEFORE_MS = 8000L
private const val CLIP_AFTER_MS = 2000L
private val TEAM_TYPES = setOf("PTS_1", "PTS_2", "PTS_3", "FT_MADE")
private val PLAYER_TYPES = TEAM_TYPES + setOf("REB", "OREB", "DREB", "AST", "STL", "BLK")

/**
 * The highlight clip rule shared with iOS and the Web (web/lib/highlight-clips.ts; the fixture
 * web/lib/highlight-clips.fixture.json pins all three). Each play becomes a window from 8 s
 * before to 2 s after it was recorded, kept inside its own recording; overlapping or touching
 * windows merge.
 */
fun highlightClips(events: List<StatEvent>, segments: List<VideoSegment>, target: HighlightTarget): List<Clip> {
    val durations = segments.filter { it.sequence > 0 }.associate { it.sequence to it.durationMs }
    val windows = events
        .filter { e ->
            !e.reverted && e.segment in durations && when (target) {
                is HighlightTarget.PlayerTarget -> e.playerId == target.playerId && e.type in PLAYER_TYPES
                is HighlightTarget.TeamTarget -> e.teamId == target.teamId && e.type in TEAM_TYPES
            }
        }
        .map { Clip(it.segment, maxOf(0L, it.segmentTimeMs - CLIP_BEFORE_MS), minOf(durations.getValue(it.segment), it.segmentTimeMs + CLIP_AFTER_MS)) }
        // A play stamped past the end of its recording has nothing to show.
        .filter { it.startMs < it.endMs }
        .sortedWith(compareBy({ it.segment }, { it.startMs }))
    val clips = mutableListOf<Clip>()
    for (w in windows) {
        val last = clips.lastOrNull()
        if (last != null && last.segment == w.segment && w.startMs <= last.endMs) clips[clips.lastIndex] = last.copy(endMs = maxOf(last.endMs, w.endMs))
        else clips += w
    }
    return clips
}

/** Highlights are 720p at 5 Mbps whatever the recording quality, matching the cloud cutter, so a few minutes stay uploadable. */
private const val HIGHLIGHT_HEIGHT = 720
private const val HIGHLIGHT_BITRATE = 5_000_000

/** What a finished highlight export produced: the published video plus its local copy for upload. */
data class HighlightResult(val uri: Uri, val file: File, val clips: Int, val skipped: Int, val durationMs: Long)

/** Clips whose recording is still readable on this phone, plus how many were dropped because it is gone. */
fun playableClips(context: Context, clips: List<Clip>, segments: List<VideoSegment>): Pair<List<Pair<Clip, Uri>>, Int> {
    val uris = segments.associate { it.sequence to it.uri }
    val readable = mutableMapOf<Int, Uri?>()
    val usable = clips.mapNotNull { clip ->
        readable.getOrPut(clip.segment) {
            uris[clip.segment]?.takeIf { it.isNotBlank() }?.let(Uri::parse)?.takeIf { uri ->
                runCatching { context.contentResolver.openFileDescriptor(uri, "r")?.use { true } ?: false }.getOrDefault(false)
            }
        }?.let { clip to it }
    }
    return usable to (clips.size - usable.size)
}

/**
 * Joins the clips into one mp4 with Media3 Transformer and publishes it to
 * Movies/HoopReplay/Highlights. Transformer must run on the main looper; [onProgress] gets 0-100.
 * Cancelling the calling coroutine stops the export and leaves nothing behind.
 */
suspend fun exportHighlight(context: Context, clips: List<Pair<Clip, Uri>>, skipped: Int, displayName: String, onProgress: (Int) -> Unit): HighlightResult {
    require(clips.isNotEmpty())
    val out = File(context.cacheDir, "highlights").apply { mkdirs() }.resolve(displayName)
    out.delete()
    val items = clips.map { (clip, uri) ->
        val clipping = MediaItem.ClippingConfiguration.Builder().setStartPositionMs(clip.startMs).setEndPositionMs(clip.endMs).build()
        EditedMediaItem.Builder(MediaItem.Builder().setUri(uri).setClippingConfiguration(clipping).build())
            .setEffects(Effects(emptyList(), listOf(Presentation.createForHeight(HIGHLIGHT_HEIGHT))))
            .build()
    }
    withContext(Dispatchers.Main) {
        coroutineScope {
            val done = CompletableDeferred<Unit>()
            val encoder = DefaultEncoderFactory.Builder(context).setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(HIGHLIGHT_BITRATE).build()).build()
            val transformer = Transformer.Builder(context).setEncoderFactory(encoder).addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) { done.complete(Unit) }
                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) { android.util.Log.e("HoopReplay", "Highlight export failed", exportException); done.completeExceptionally(exportException) }
            }).build()
            // Recordings made without microphone access have no audio track; a forced track fills them with silence so they still join.
            transformer.start(Composition.Builder(EditedMediaItemSequence(items)).experimentalSetForceAudioTrack(true).build(), out.absolutePath)
            val progress = ProgressHolder()
            val poll = launch {
                while (isActive) {
                    if (transformer.getProgress(progress) == Transformer.PROGRESS_STATE_AVAILABLE) onProgress(progress.progress)
                    delay(250)
                }
            }
            try { done.await() } catch (e: CancellationException) { transformer.cancel(); out.delete(); throw e } finally { poll.cancel() }
        }
    }
    val uri = withContext(Dispatchers.IO) { publishToMovies(context, out, displayName) }
    return HighlightResult(uri, out, clips.size, skipped, clips.sumOf { it.first.endMs - it.first.startMs })
}

private fun publishToMovies(context: Context, file: File, displayName: String): Uri {
    val resolver = context.contentResolver
    val values = ContentValues().apply {
        put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
        put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/HoopReplay/Highlights")
        put(MediaStore.Video.Media.IS_PENDING, 1)
    }
    val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: error("Could not create the video file")
    resolver.openOutputStream(uri)!!.use { output -> file.inputStream().use { it.copyTo(output) } }
    resolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
    return uri
}
