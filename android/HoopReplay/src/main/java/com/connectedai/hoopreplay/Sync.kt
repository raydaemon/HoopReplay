package com.connectedai.hoopreplay

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object HoopSync {
    private val ENTITIES=listOf("teams" to "teams","players" to "players","games" to "games","segments" to "segments","events" to "events")
    private const val CREDENTIAL_KEY_ALIAS="hoop_credential_key"
    /** Supabase's PostgREST max_rows; a GET never returns more than this many rows. */
    private const val PAGE_SIZE=1000

    /** The auth server refused the credentials or the refresh token, as opposed to being unreachable. */
    private class AuthRejectedException(message:String):IllegalStateException(message)

    val configured:Boolean get()=BuildConfig.SUPABASE_URL.isNotBlank()&&BuildConfig.SUPABASE_ANON_KEY.isNotBlank()&&BuildConfig.SYNC_SPACE.isNotBlank()

    fun isSignedIn(context:Context)=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).getString("access_token",null)!=null

    fun signedInEmail(context:Context)=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).getString("email","").orEmpty()

    /** The name the account chose (or its provider supplied), or "" when the account only has an email. */
    fun signedInName(context:Context)=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).getString("display_name","").orEmpty()

    /**
     * Ends the session but keeps the remembered email and password, so signing back in is a
     * single tap. Use [forgetCredentials] to drop those as well.
     */
    fun signOut(context:Context)=clearSession(context)

    fun forgetCredentials(context:Context)=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).edit().clear().apply()

    private fun clearSession(context:Context)=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).edit()
        .remove("access_token").remove("refresh_token").remove("expires_at").remove("user_id").remove("display_name").apply()

    /** The key never leaves the Android keystore, so the stored password is useless off-device. */
    private fun credentialKey():SecretKey{
        val store=KeyStore.getInstance("AndroidKeyStore").apply{load(null)}
        (store.getEntry(CREDENTIAL_KEY_ALIAS,null) as? KeyStore.SecretKeyEntry)?.let{return it.secretKey}
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply{
            init(KeyGenParameterSpec.Builder(CREDENTIAL_KEY_ALIAS,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build())
        }.generateKey()
    }

    fun rememberCredentials(context:Context,email:String,password:String){
        val edit=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).edit().putString("email",email.trim())
        runCatching{
            val cipher=Cipher.getInstance("AES/GCM/NoPadding").apply{init(Cipher.ENCRYPT_MODE,credentialKey())}
            val secret=cipher.doFinal(password.toByteArray())
            edit.putString("password_iv",Base64.encodeToString(cipher.iv,Base64.NO_WRAP))
                .putString("password_secret",Base64.encodeToString(secret,Base64.NO_WRAP))
        }
        edit.apply()
    }

    /** The remembered password, or "" when none was stored or the keystore entry is gone. */
    fun rememberedPassword(context:Context):String{
        val prefs=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE)
        val iv=prefs.getString("password_iv",null)?:return ""
        val secret=prefs.getString("password_secret",null)?:return ""
        return runCatching{
            val cipher=Cipher.getInstance("AES/GCM/NoPadding").apply{
                init(Cipher.DECRYPT_MODE,credentialKey(),GCMParameterSpec(128,Base64.decode(iv,Base64.NO_WRAP)))
            }
            String(cipher.doFinal(Base64.decode(secret,Base64.NO_WRAP)))
        }.getOrDefault("")
    }

    suspend fun authenticate(context:Context,email:String,password:String,signUp:Boolean)=withContext(Dispatchers.IO){
        require(configured){t("Sync is not configured")}
        refreshRemoteConfig(context)
        val body=JSONObject().put("email",email.trim()).put("password",password).toString()
        val path=if(signUp)"/auth/v1/signup" else "/auth/v1/token?grant_type=password"
        val json=JSONObject(authRequest(context,path,body))
        if(json.optString("access_token").isBlank()) error("Check your email to confirm the account, then sign in")
        val userEmail=storeSession(context,json,email.trim())
        // Keep the credentials for the next sign-in prompt, so a session that does expire costs
        // one tap rather than typing an email and password again.
        rememberCredentials(context,userEmail,password)
    }

    /** Where the browser sends the user back after a Google or Apple sign-in. */
    private const val OAUTH_REDIRECT="hoopreplay://auth-callback"
    /** The web app, whose API runs the Google and Apple sign-ins and publishes the client configuration. */
    private const val WEB_URL="https://www.hoopreplay.com"

    /**
     * Public client configuration (Supabase URL, anon key, sync space), fetched from the web app
     * before each sign-in and cached, so the backend can move without a store release. The values
     * compiled into BuildConfig are the fallback when the web app cannot be reached.
     */
    private fun refreshRemoteConfig(context:Context){
        runCatching{
            val connection=(URI("$WEB_URL/api/config").toURL().openConnection() as HttpURLConnection).apply{connectTimeout=5_000;readTimeout=5_000}
            val json=JSONObject(connection.inputStream.bufferedReader().use{it.readText()}).also{connection.disconnect()}
            context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).edit()
                .putString("cfg_supabase_url",json.optString("supabase_url"))
                .putString("cfg_anon_key",json.optString("supabase_anon_key"))
                .putString("cfg_sync_space",json.optString("sync_space")).apply()
        }
    }
    private fun cfg(context:Context,key:String,fallback:String)=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).getString(key,null)?.takeIf{it.isNotBlank()}?:fallback
    private fun supabaseUrl(context:Context)=cfg(context,"cfg_supabase_url",BuildConfig.SUPABASE_URL).trimEnd('/')
    private fun anonKey(context:Context)=cfg(context,"cfg_anon_key",BuildConfig.SUPABASE_ANON_KEY)
    private fun syncSpace(context:Context)=cfg(context,"cfg_sync_space",BuildConfig.SYNC_SPACE)

    /**
     * Google / Apple sign-in without a Supabase provider: the browser opens our web API, which
     * sends the user to the provider, mints the Supabase session itself, and returns it to the
     * app in the fragment of the `hoopreplay://auth-callback` link; [completeOAuthSignIn] stores it.
     */
    private fun beginWebSignIn(context:Context,provider:String){
        require(configured){t("Sync is not configured")}
        // Any app on the device can fire our deep link; the state ties the callback to this sign-in.
        val state=randomToken()
        // PKCE: the deep link carries only a code, which only the holder of this verifier can redeem.
        val verifier=randomToken()
        val challenge=base64Url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
        context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).edit().putString("oauth_state",state).putString("oauth_verifier",verifier).apply()
        val url=WEB_URL+"/api/login/"+provider+"/start?redirect_to="+URLEncoder.encode(OAUTH_REDIRECT,"UTF-8")+"&state="+state+"&code_challenge="+challenge
        context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun base64Url(bytes:ByteArray)=Base64.encodeToString(bytes,Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun randomToken()=base64Url(ByteArray(32).also{SecureRandom().nextBytes(it)})

    /** Redeems the deep link's sign-in code for the session fields, proving with the PKCE verifier that this app started it. */
    private fun exchangeCode(code:String,verifier:String):JSONObject{
        val connection=(URI("$WEB_URL/api/login/exchange").toURL().openConnection() as HttpURLConnection).apply{
            requestMethod="POST";connectTimeout=15_000;readTimeout=20_000;doOutput=true
            setRequestProperty("Content-Type","application/json")
            outputStream.bufferedWriter().use{it.write(JSONObject().put("code",code).put("code_verifier",verifier).toString())}
        }
        val status=connection.responseCode
        val text=(if(status in 200..299)connection.inputStream else connection.errorStream)?.bufferedReader()?.use{it.readText()}.orEmpty()
        connection.disconnect()
        check(status in 200..299){runCatching{JSONObject(text).optString("error")}.getOrNull()?.takeIf{it.isNotBlank()}?:t("Sign in expired. Try again")}
        return JSONObject(text)
    }

    fun beginGoogleSignIn(context:Context)=beginWebSignIn(context,"google")

    fun beginAppleSignIn(context:Context)=beginWebSignIn(context,"apple")

    private fun callbackFragment(uri:Uri)=uri.fragment?.let{Uri.parse("hoopreplay://x?$it")}

    /** True when [intent] is the browser's return from a sign-in. Throws on a provider error. */
    fun isOAuthCallback(intent:Intent?):Boolean{
        val uri=intent?.data?:return false
        if(uri.scheme!="hoopreplay"||uri.host!="auth-callback")return false
        val error=callbackFragment(uri)?.getQueryParameter("login_error")
        if(error!=null)throw IllegalStateException(error)
        return true
    }

    suspend fun completeOAuthSignIn(context:Context,intent:Intent)=withContext(Dispatchers.IO){
        val fragment=callbackFragment(intent.data!!)?:error(t("Sign in was cancelled"))
        // Only the sign-in this app started may deliver a session.
        val prefs=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE)
        val expected=prefs.getString("oauth_state",null)
        val verifier=prefs.getString("oauth_verifier",null)
        prefs.edit().remove("oauth_state").remove("oauth_verifier").apply()
        check(expected!=null&&verifier!=null&&expected==fragment.getQueryParameter("state")){t("Sign in expired. Try again")}
        val code=fragment.getQueryParameter("code")?:error(t("Sign in failed: no session returned"))
        val fields=exchangeCode(code,verifier)
        val json=JSONObject().put("access_token",fields.optString("access_token")).put("refresh_token",fields.optString("refresh_token"))
            .put("expires_at",fields.optString("expires_at").toLongOrNull()?:0L)
            .put("user",JSONObject().put("id",fields.optString("user_id")).put("email",fields.optString("email"))
                .put("user_metadata",JSONObject().put("full_name",fields.optString("name"))))
        check(json.optString("access_token").isNotBlank()){t("Sign in failed: no session returned")}
        refreshRemoteConfig(context)
        storeSession(context,json,"")
    }

    /** Stores the session from an auth response and returns the account email it carried. */
    private fun storeSession(context:Context,json:JSONObject,fallbackEmail:String):String{
        val user=json.optJSONObject("user")?:JSONObject()
        val meta=user.optJSONObject("user_metadata")?:JSONObject()
        val name=listOf("display_name","full_name","name").map{meta.optString(it).trim()}.firstOrNull{it.isNotBlank()}.orEmpty()
        val userEmail=user.optString("email").ifBlank{fallbackEmail}
        context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).edit()
            .putString("access_token",json.getString("access_token"))
            .putString("refresh_token",json.getString("refresh_token"))
            .putString("user_id",user.getString("id"))
            .putString("email",userEmail)
            .putString("display_name",name)
            .putLong("expires_at",json.optLong("expires_at",System.currentTimeMillis()/1000+json.optLong("expires_in",3600)))
            .apply()
        I18n.adoptFromAccount(context,meta.optString(I18n.KEY).takeIf{it.isNotBlank()})
        return userEmail
    }

    /** Stores the interface language on the account (user_metadata.language) so Web and iOS pick it up. */
    suspend fun updateLanguage(context:Context,code:String)=withContext(Dispatchers.IO){
        request(context,"PUT","/auth/v1/user",JSONObject().put("data",JSONObject().put(I18n.KEY,code)).toString())
    }

    /**
     * The server's change counter for this account and sync space, or 0 when nothing has ever
     * been written. Every write from any client bumps it (see the `bump_sync_revision` trigger).
     */
    private fun remoteRevision(context:Context):Long{
        val rows=JSONArray(request(context,"GET","/rest/v1/hoop_sync_revisions?select=revision"))
        return (0 until rows.length()).maxOfOrNull{rows.getJSONObject(it).optLong("revision")} ?: 0L
    }

    private fun seenRevision(context:Context)=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).getLong("sync_revision",-1L)

    private fun rememberRevision(context:Context,revision:Long)=
        context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE).edit().putLong("sync_revision",revision).apply()

    private data class Tombstone(val entity:String,val localId:Long,val deletedAt:Long,val deviceId:String)

    private fun tombstonesOf(rows:JSONArray):List<Tombstone> =
        (0 until rows.length()).map{rows.getJSONObject(it)}
            .map{Tombstone(it.optString("entity"),it.optLong("local_id"),it.optLong("deleted_at"),it.optString("device_id"))}

    /**
     * Uploads this device's data.
     *
     * A row missing from the snapshot never means "delete it" — that is how one device used to wipe
     * another's work. Removals travel as tombstones instead: they are recorded, then replayed
     * against the server so every other device sees the same deletion.
     *
     * A push also refuses to run while the server holds changes this device has not pulled — for
     * example a team deleted on the web. Uploading over them would resurrect what the other client
     * removed, so the user downloads and merges first.
     */
    suspend fun push(context:Context,db:HoopDb)=withContext(Dispatchers.IO){
        require(configured){t("Sync is not configured")}
        val revision=remoteRevision(context)
        val seen=seenRevision(context)
        // An empty account has nothing to lose, so a first upload from a device that never pulled is fine.
        check(revision==seen||(revision==0L&&seen<0)){t("Cloud has newer changes. Download first, then upload")}
        val prefs=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE)
        val userId=prefs.getString("user_id","").orEmpty()
        val space=syncSpace(context)
        val scope="user_id=eq.$userId&sync_space=eq."+URLEncoder.encode(space,"UTF-8")
        // Events are authoritative; repair denormalized score/clock fields before serializing the
        // game rows so a stale summary cannot overwrite correct play-by-play data in the cloud.
        db.games().forEach { db.reconcileGameSummary(it.id) }
        val snapshot=db.exportSyncSnapshot()
        val gameIds=(snapshot.optJSONArray("games")?:JSONArray()).let{rows->
            (0 until rows.length()).map{rows.getJSONObject(it).optLong("id")}.toSet()
        }
        val liveIds=ENTITIES.associate{(table,key)->
            val rows=snapshot.optJSONArray(key)?:JSONArray()
            table to (0 until rows.length()).map{rows.getJSONObject(it).optLong("id")}.toSet()
        }

        // A local id that SQLite handed out again outlives its old tombstone, here and on the server.
        val remote=tombstonesOf(requestRows(context,"/rest/v1/hoop_deletions?select=entity,local_id,deleted_at,device_id"))
        val local=tombstonesOf(db.pendingDeletions())
        val (resurrected,current)=(remote+local).distinctBy{it.entity to it.localId}
            .partition{liveIds[it.entity]?.contains(it.localId)==true}

        if(local.isNotEmpty()){
            val rows=JSONArray()
            local.filterNot{tombstone->resurrected.any{it.entity==tombstone.entity&&it.localId==tombstone.localId}}.forEach{
                rows.put(JSONObject().put("user_id",userId).put("sync_space",space)
                    .put("entity",it.entity).put("local_id",it.localId)
                    .put("deleted_at",it.deletedAt).put("device_id",it.deviceId))
            }
            if(rows.length()>0)request(context,"POST","/rest/v1/hoop_deletions?on_conflict=user_id,sync_space,entity,local_id",rows.toString(),"resolution=merge-duplicates,return=minimal")
        }
        resurrected.forEach{
            request(context,"DELETE","/rest/v1/hoop_deletions?$scope&entity=eq.${it.entity}&local_id=eq.${it.localId}",null,"return=minimal")
        }

        // Surviving rows first: a player can only be removed once the events naming them let go.
        ENTITIES.forEach{(table,key)->
            val exportedRows=snapshot.optJSONArray(key)?:JSONArray()
            // Older local databases could retain child rows after their game was removed.
            // The cloud schema enforces the composite game foreign key, so do not upload rows
            // that cannot have a valid parent. They are not syncable records anymore.
            val localRows=if(table=="segments"||table=="events") JSONArray().also{filtered->
                for(index in 0 until exportedRows.length()){
                    val row=exportedRows.getJSONObject(index)
                    if(gameIds.contains(row.optLong("game_id")))filtered.put(row)
                }
            } else exportedRows
            if(localRows.length()>0){
                val cloudRows=JSONArray()
                for(index in 0 until localRows.length()){
                    val row=JSONObject(localRows.getJSONObject(index).toString())
                    row.put("local_id",row.remove("id")).put("user_id",userId).put("sync_space",space)
                    if(table=="events"&&row.optString("type")=="FOULED")row.put("type","FOUL_DRAWN")
                    if(table=="events"&&row.has("reverted"))row.put("reverted",row.optInt("reverted")!=0)
                    cloudRows.put(row)
                }
                request(context,"POST","/rest/v1/hoop_$table?on_conflict=user_id,sync_space,local_id",cloudRows.toString(),"resolution=merge-duplicates,return=minimal")
            }
        }

        // Dependent rows first so the relational schema stays valid while tombstones are applied.
        listOf("events","segments","games","players","teams").forEach{entity->
            current.filter{it.entity==entity}.map{it.localId}.chunked(100).forEach{batch->
                request(context,"DELETE","/rest/v1/hoop_$entity?$scope&local_id=in.(${batch.joinToString(",")})",null,"return=minimal")
            }
        }
        rememberRevision(context,remoteRevision(context))
    }

    suspend fun pull(context:Context,db:HoopDb)=withContext(Dispatchers.IO){
        require(configured){t("Sync is not configured")}
        // Read before the rows: a write that lands mid-pull then still counts as unseen.
        val revision=remoteRevision(context)
        val snapshot=JSONObject().put("schemaVersion",2).put("updatedAt",System.currentTimeMillis())
        val cloudDeletions=requestRows(context,"/rest/v1/hoop_deletions?select=entity,local_id,deleted_at,device_id&order=deleted_at.asc")
        val deletions=JSONArray()
        for(index in 0 until cloudDeletions.length())deletions.put(JSONObject(cloudDeletions.getJSONObject(index).toString()))
        snapshot.put("deletions",deletions)
        listOf("teams","players","games","events","segments").forEach{table->
            val cloudRows=requestRows(context,"/rest/v1/hoop_$table?select=*&order=local_id.asc")
            val localRows=JSONArray()
            for(index in 0 until cloudRows.length()){
                val row=JSONObject(cloudRows.getJSONObject(index).toString())
                row.put("id",row.remove("local_id"));row.remove("user_id");row.remove("sync_space")
                if(table=="events"&&row.has("reverted"))row.put("reverted",if(row.optBoolean("reverted"))1 else 0)
                localRows.put(row)
            }
            snapshot.put(table,localRows)
        }
        db.mergeSyncSnapshot(snapshot)
        rememberRevision(context,revision)
    }

    private fun authRequest(context:Context,path:String,body:String):String{
        val connection=(URI(supabaseUrl(context)+path).toURL().openConnection() as HttpURLConnection).apply{
            requestMethod="POST";connectTimeout=15_000;readTimeout=20_000;doOutput=true
            setRequestProperty("apikey",anonKey(context));setRequestProperty("Content-Type","application/json")
            outputStream.bufferedWriter().use{it.write(body)}
        }
        val code=connection.responseCode
        val text=(if(code in 200..299)connection.inputStream else connection.errorStream)?.bufferedReader()?.use{it.readText()}.orEmpty()
        connection.disconnect()
        // A refusal and an unreachable server must stay distinguishable: only the first one may
        // end the session, so the caller can tell them apart by exception type.
        if(code==400||code==401||code==403)throw AuthRejectedException(t("Sign in failed ({code}): {text}","code" to code,"text" to text))
        check(code in 200..299){t("Sign in failed ({code}): {text}","code" to code,"text" to text)}
        return text
    }

    /**
     * Every row of a GET: PostgREST caps a response at the project's max_rows (1000), which
     * silently dropped the newest events of a busy account, so read page by page until a short
     * page says the table is done. [path] already carries its own query string.
     */
    private fun requestRows(context:Context,path:String):JSONArray{
        val rows=JSONArray()
        var offset=0
        while(true){
            val page=JSONArray(request(context,"GET","$path&limit=$PAGE_SIZE&offset=$offset"))
            for(index in 0 until page.length())rows.put(page.get(index))
            if(page.length()<PAGE_SIZE)return rows
            offset+=PAGE_SIZE
        }
    }

    private fun request(context:Context,method:String,path:String,body:String?=null,prefer:String?=null,retried:Boolean=false):String{
        val token=validAccessToken(context)
        val connection=(URI(supabaseUrl(context)+path).toURL().openConnection() as HttpURLConnection).apply{
            requestMethod=method
            connectTimeout=15_000
            readTimeout=20_000
            setRequestProperty("apikey",anonKey(context))
            setRequestProperty("Authorization","Bearer $token")
            setRequestProperty("Content-Type","application/json")
            setRequestProperty("x-sync-space",syncSpace(context))
            if(prefer!=null)setRequestProperty("Prefer",prefer)
            if(body!=null){doOutput=true;outputStream.bufferedWriter().use{it.write(body)}}
        }
        val code=connection.responseCode
        val text=(if(code in 200..299)connection.inputStream else connection.errorStream)?.bufferedReader()?.use{it.readText()}.orEmpty()
        connection.disconnect()
        // A rejected access token is not a dead session: it usually just aged out (or the device
        // clock drifted). Refresh once and retry before making the user sign in again.
        if(code==401&&!retried){
            refreshAccessToken(context)
            return request(context,method,path,body,prefer,retried=true)
        }
        check(code in 200..299){t("Sync failed ({code}): {text}","code" to code,"text" to text)}
        return text
    }

    /** Calls a Web API route (e.g. /api/highlights/upload) as the signed-in user; returns the body, throws its error. */
    internal fun webRequest(context:Context,method:String,path:String,body:JSONObject?=null,retried:Boolean=false):String{
        val token=validAccessToken(context)
        val connection=(URI(WEB_URL+path).toURL().openConnection() as HttpURLConnection).apply{
            requestMethod=method
            connectTimeout=15_000
            readTimeout=60_000
            setRequestProperty("Authorization","Bearer $token")
            setRequestProperty("Content-Type","application/json")
            if(body!=null){doOutput=true;outputStream.bufferedWriter().use{it.write(body.toString())}}
        }
        val code=connection.responseCode
        val text=(if(code in 200..299)connection.inputStream else connection.errorStream)?.bufferedReader()?.use{it.readText()}.orEmpty()
        connection.disconnect()
        if(code==401&&!retried){refreshAccessToken(context);return webRequest(context,method,path,body,retried=true)}
        check(code in 200..299){runCatching{JSONObject(text).optString("error")}.getOrNull()?.takeIf{it.isNotBlank()}?:t("Request failed ({code})","code" to code)}
        return text
    }

    /** The cloud uuid of a local game, which the Web API routes key everything by; null until the game has synced. */
    internal fun gameUuid(context:Context,gameId:Long):String?{
        val rows=JSONArray(request(context,"GET","/rest/v1/hoop_games?local_id=eq.$gameId&select=uuid_id&limit=1"))
        return if(rows.length()==0)null else rows.getJSONObject(0).optString("uuid_id").takeIf{it.isNotBlank()}
    }

    private fun validAccessToken(context:Context):String{
        val prefs=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE)
        val current=prefs.getString("access_token",null) ?: error(t("Sign in required"))
        if(prefs.getLong("expires_at",0)>System.currentTimeMillis()/1000+60)return current
        return refreshAccessToken(context)
    }

    /**
     * Trades the refresh token for a fresh access token. Only an explicit refusal from the auth
     * server ends the session — a timeout or a dropped connection leaves the stored tokens alone,
     * because otherwise every stretch without signal would sign the user out.
     */
    private fun refreshAccessToken(context:Context):String{
        val prefs=context.getSharedPreferences("hoop_auth",Context.MODE_PRIVATE)
        val refresh=prefs.getString("refresh_token",null) ?: run{clearSession(context);error(t("Session expired. Please sign in again"))}
        val json=try {
            JSONObject(authRequest(context,"/auth/v1/token?grant_type=refresh_token",JSONObject().put("refresh_token",refresh).toString()))
        } catch (rejected:AuthRejectedException) {
            // Supabase invalidates refresh tokens after sign-out, rotation, or account changes.
            // Do not leave the UI looking signed in with a session that can no longer sync.
            clearSession(context)
            throw IllegalStateException(t("Session expired. Please sign in again"), rejected)
        }
        storeSession(context,json,signedInEmail(context))
        return json.getString("access_token")
    }
}
