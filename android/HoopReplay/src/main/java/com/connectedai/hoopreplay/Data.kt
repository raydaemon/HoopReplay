package com.connectedai.hoopreplay

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

/** [ownerId] is null for this account's own teams; a shared team (and its roster) is read-only. */
data class Team(val id: String, val name: String, val ownerId: String? = null)
data class Player(val id: String, val teamId: String, val name: String, val number: String) {
    /** "#12 Haoxuan Tan"; a player without a jersey number shows only the name, never "#--". */
    val label: String get() = if (number.isBlank()) name.trim() else "#${number.trim()} ${name.trim()}".trim()
}
/** [ownerId] is null for this account's own games; a game shared by someone else is a read-only copy. */
data class Game(val id: String, val title: String, val homeId: String, val awayId: String, val homeName: String, val awayName: String, val homeScore: Int, val awayScore: Int, val status: String, val scheduledAt: Long, val videoQuality: String, val periodCount: Int, val periodDurationMs: Long, val currentPeriod: Int, val clockRemainingMs: Long, val ownerId: String? = null)
data class GameImport(val gameId: String, val events: Int, val createdTeams: Int, val createdPlayers: Int)
data class StatEvent(val id: String, val gameId: String, val teamId: String, val playerId: String?, val type: String, val value: Int, val period: Int, val gameClockMs: Long, val segment: Int, val segmentTimeMs: Long, val finalVideoTimeMs: Long, val reverted: Boolean)

private const val GAME_EXPORT_KIND = "hoopreplay.game"
private const val LEGACY = "legacy:"
private val DELETABLE_ENTITIES = listOf("teams" to "team", "players" to "player", "games" to "game", "events" to "event", "segments" to "segment")

/**
 * Local tables. Every id is the row's UUID string; `owner_id` is null for this account's own rows
 * and holds the owner's user id for rows shared by someone else (read-only, never pushed).
 */
private val TABLES = linkedMapOf(
    "team" to "(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at INTEGER NOT NULL, owner_id TEXT, sync_space TEXT)",
    "player" to "(id TEXT PRIMARY KEY, team_id TEXT NOT NULL, name TEXT NOT NULL, number TEXT NOT NULL, owner_id TEXT, sync_space TEXT)",
    "game" to "(id TEXT PRIMARY KEY, title TEXT NOT NULL, home_id TEXT NOT NULL, away_id TEXT NOT NULL, home_score INTEGER NOT NULL DEFAULT 0, away_score INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, scheduled_at INTEGER NOT NULL, video_quality TEXT NOT NULL DEFAULT 'HIGHEST', period_count INTEGER NOT NULL DEFAULT 4, period_duration_ms INTEGER NOT NULL DEFAULT 480000, current_period INTEGER NOT NULL DEFAULT 1, clock_remaining_ms INTEGER NOT NULL DEFAULT 480000, created_at INTEGER NOT NULL, owner_id TEXT, sync_space TEXT)",
    "event" to "(id TEXT PRIMARY KEY, game_id TEXT NOT NULL, team_id TEXT NOT NULL, player_id TEXT, type TEXT NOT NULL, value INTEGER NOT NULL, period INTEGER NOT NULL, game_clock_ms INTEGER NOT NULL, segment INTEGER NOT NULL, segment_time_ms INTEGER NOT NULL, final_video_time_ms INTEGER NOT NULL, reverted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, owner_id TEXT, sync_space TEXT)",
    "player_game_stat" to "(game_id TEXT NOT NULL, player_id TEXT NOT NULL, minutes_ms INTEGER NOT NULL DEFAULT 0, plus_minus INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(game_id,player_id))",
    "segment" to "(id TEXT PRIMARY KEY, game_id TEXT NOT NULL, sequence INTEGER NOT NULL, uri TEXT NOT NULL, duration_ms INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, owner_id TEXT, sync_space TEXT)",
    "deletion" to "(entity TEXT NOT NULL, row_id TEXT NOT NULL, deleted_at INTEGER NOT NULL, device_id TEXT NOT NULL, PRIMARY KEY(entity, row_id))",
)

/**
 * Integer id/reference columns of the version-9 schema, converted to `legacy:<n>` placeholders on
 * upgrade, and the columns that name each entity's rows (for rewriting a placeholder to its uuid).
 */
private val ENTITY_COLUMNS = mapOf(
    "teams" to listOf("team" to "id", "player" to "team_id", "game" to "home_id", "game" to "away_id", "event" to "team_id"),
    "players" to listOf("player" to "id", "event" to "player_id", "player_game_stat" to "player_id"),
    "games" to listOf("game" to "id", "event" to "game_id", "segment" to "game_id", "player_game_stat" to "game_id"),
    "events" to listOf("event" to "id"),
    "segments" to listOf("segment" to "id"),
)

private val uuidRandom = SecureRandom()
private var lastUuidMs = 0L

/** A fresh UUIDv7 whose time prefix never repeats on this device, so two rows made in one ms still sort in order. */
@Synchronized internal fun uuidV7(): String {
    lastUuidMs = maxOf(System.currentTimeMillis(), lastUuidMs + 1)
    return uuidV7(lastUuidMs)
}

/** A lowercase canonical UUIDv7: 48-bit Unix ms prefix, so ids sort by creation time. */
internal fun uuidV7(timeMs: Long): String {
    val b = ByteArray(16).also(uuidRandom::nextBytes)
    for (i in 0..5) b[i] = (timeMs shr (40 - 8 * i)).toByte()
    b[6] = ((b[6].toInt() and 0x0f) or 0x70).toByte()
    b[8] = ((b[8].toInt() and 0x3f) or 0x80).toByte()
    val hex = b.joinToString("") { "%02x".format(it) }
    return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}"
}

/** A leftover `legacy:<n>` id keeps its creation time: old ids were creation_ms * 1000 + salt. */
private fun legacyTime(legacy: String): Long =
    legacy.removePrefix(LEGACY).toLongOrNull()?.takeIf { it >= 1_000_000_000_000L }?.let { it / 1000 } ?: System.currentTimeMillis()

internal fun String.capitalizeInitial(): String {
    val firstLetter = indexOfFirst(Char::isLetter)
    if (firstLetter == -1) return this
    return replaceRange(firstLetter, firstLetter + 1, this[firstLetter].titlecase())
}

class HoopDb(private val context: Context) : SQLiteOpenHelper(context, "hoopreplay.db", null, 10) {
    override fun onCreate(db: SQLiteDatabase) {
        TABLES.forEach { (table, columns) -> db.execSQL("CREATE TABLE $table$columns") }
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE game ADD COLUMN scheduled_at INTEGER NOT NULL DEFAULT 0")
            db.execSQL("UPDATE game SET scheduled_at=created_at WHERE scheduled_at=0")
        }
        if (oldVersion < 3) db.execSQL("ALTER TABLE game ADD COLUMN video_quality TEXT NOT NULL DEFAULT 'HIGHEST'")
        if (oldVersion < 4) {
            db.execSQL("ALTER TABLE game ADD COLUMN period_count INTEGER NOT NULL DEFAULT 4")
            db.execSQL("ALTER TABLE game ADD COLUMN period_duration_ms INTEGER NOT NULL DEFAULT 480000")
        }
        if (oldVersion < 5) {
            db.execSQL("ALTER TABLE game ADD COLUMN current_period INTEGER NOT NULL DEFAULT 1")
            db.execSQL("ALTER TABLE game ADD COLUMN clock_remaining_ms INTEGER NOT NULL DEFAULT 480000")
            db.execSQL("UPDATE game SET clock_remaining_ms=period_duration_ms")
        }
        if (oldVersion < 6) db.execSQL("CREATE TABLE IF NOT EXISTS deletion(entity TEXT NOT NULL, local_id INTEGER NOT NULL, deleted_at INTEGER NOT NULL, device_id TEXT NOT NULL, PRIMARY KEY(entity, local_id))")
        // An older build wrote rebounds as "REBOUND"; the server only accepts "REB", so those rows
        // failed to sync with an event_type_check violation until they are normalized here.
        if (oldVersion < 7) db.execSQL("UPDATE event SET type='REB' WHERE type='REBOUND'")
        if (oldVersion < 8) db.execSQL("CREATE TABLE player_game_stat(game_id INTEGER NOT NULL, player_id INTEGER NOT NULL, minutes_ms INTEGER NOT NULL DEFAULT 0, plus_minus INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(game_id,player_id))")
        // Older Android builds stored the display-only alias FOULED; the cloud accepts FOUL_DRAWN.
        if (oldVersion < 9) db.execSQL("UPDATE event SET type='FOUL_DRAWN' WHERE type='FOULED'")
        // Integer ids become `legacy:<n>` placeholders (relationships kept). SQLite cannot change a
        // column's type in place, so each table is rebuilt; onUpgrade runs inside one transaction.
        // The next signed-in sync swaps every placeholder for the server's uuid (adoptLegacyIds).
        if (oldVersion < 10) {
            val idColumns = ENTITY_COLUMNS.values.flatten().groupBy({ it.first }, { it.second }) + mapOf("deletion" to listOf("local_id"))
            TABLES.forEach { (table, columns) ->
                val old = db.rawQuery("PRAGMA table_info($table)", null).use { c -> buildList { while (c.moveToNext()) add(c.getString(1)) } }
                db.execSQL("CREATE TABLE ${table}_v10$columns")
                val selected = old.map { column ->
                    when {
                        column in idColumns[table].orEmpty() -> "CASE WHEN $column IS NULL THEN NULL ELSE '$LEGACY' || $column END"
                        else -> column
                    }
                }
                val target = old.map { if (table == "deletion" && it == "local_id") "row_id" else it }
                db.execSQL("INSERT INTO ${table}_v10(${target.joinToString(",")}) SELECT ${selected.joinToString(",")} FROM $table")
                db.execSQL("DROP TABLE $table")
                db.execSQL("ALTER TABLE ${table}_v10 RENAME TO $table")
            }
        }
    }

    /**
     * A deletion has to be recorded, never inferred from a row's absence: sync used to push only the
     * rows this device still had, so nothing ever told the other devices that a game was gone.
     */
    private fun deviceId(): String {
        val prefs = context.getSharedPreferences("hoop_sync", Context.MODE_PRIVATE)
        prefs.getString("device_id", null)?.let { return it }
        val created = "android-" + java.util.UUID.randomUUID()
        prefs.edit().putString("device_id", created).apply()
        return created
    }
    /** Tombstones only this account's own rows: a shared game's copy is not ours to delete in the cloud. */
    private fun recordDeletions(db: SQLiteDatabase, entity: String, table: String, ids: List<String>) {
        val deletedAt = System.currentTimeMillis()
        val device = deviceId()
        ids.filter { id -> db.rawQuery("SELECT 1 FROM $table WHERE id=? AND owner_id IS NULL", arrayOf(id)).use { it.moveToFirst() } }.forEach { id ->
            db.insertWithOnConflict("deletion", null, ContentValues().apply {
                put("entity", entity); put("row_id", id); put("deleted_at", deletedAt); put("device_id", device)
            }, SQLiteDatabase.CONFLICT_REPLACE)
        }
    }
    private fun idsOf(sql: String, args: Array<String>): List<String> =
        readableDatabase.rawQuery(sql, args).use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }

    fun addTeam(name: String): String = uuidV7().also { id -> writableDatabase.insertOrThrow("team", null, ContentValues().apply { put("id", id); put("name", name.capitalizeInitial()); put("created_at", System.currentTimeMillis()) }) }
    fun teams(): List<Team> = readableDatabase.rawQuery("SELECT id,name,owner_id FROM team ORDER BY created_at,id", null).use { c -> buildList { while(c.moveToNext()) add(Team(c.getString(0), c.getString(1), c.getString(2))) } }
    fun deleteTeam(id: String): Boolean {
        val inUse = readableDatabase.rawQuery("SELECT 1 FROM game WHERE home_id=? OR away_id=? LIMIT 1", arrayOf(id, id)).use { it.moveToFirst() }
        if (inUse) return false
        writableDatabase.beginTransaction()
        return try {
            recordDeletions(writableDatabase, "players", "player", idsOf("SELECT id FROM player WHERE team_id=?", arrayOf(id)))
            recordDeletions(writableDatabase, "teams", "team", listOf(id))
            writableDatabase.delete("player", "team_id=?", arrayOf(id))
            val deleted = writableDatabase.delete("team", "id=?", arrayOf(id)) > 0
            writableDatabase.setTransactionSuccessful()
            deleted
        } finally { writableDatabase.endTransaction() }
    }
    fun findPlayer(team: String, name: String, number: String): Player? {
        val cleanName = name.capitalizeInitial().trim()
        val cleanNumber = number.trim()
        val roster = players(team)
        return if (cleanNumber.isNotBlank()) roster.firstOrNull { it.number.trim() == cleanNumber }
        else roster.firstOrNull { it.number.isBlank() && cleanName.isNotBlank() && it.name.equals(cleanName, true) }
    }
    /** Reuses the existing player when the jersey number (or the name, for unnumbered players) already exists on the team. */
    fun addPlayer(team: String, name: String, number: String): String =
        findPlayer(team, name, number)?.id
            ?: uuidV7().also { id -> writableDatabase.insertOrThrow("player", null, ContentValues().apply { put("id", id); put("team_id", team); put("name", name.capitalizeInitial()); put("number", number) }) }
    fun players(team: String): List<Player> = readableDatabase.rawQuery("SELECT id,team_id,name,number FROM player WHERE team_id=? ORDER BY CAST(number AS INTEGER)", arrayOf(team)).use { c -> buildList { while(c.moveToNext()) add(Player(c.getString(0),c.getString(1),c.getString(2),c.getString(3))) } }
    /** Renames a player / changes their jersey number in place, so recorded stats stay attached. */
    fun updatePlayer(id: String, name: String, number: String) =
        writableDatabase.update("player", ContentValues().apply { put("name", name.trim().capitalizeInitial()); put("number", number.trim()) }, "id=?", arrayOf(id))
    fun playerHasEvents(id: String): Boolean = readableDatabase.rawQuery("SELECT 1 FROM event WHERE player_id=? LIMIT 1", arrayOf(id)).use { it.moveToNext() }
    fun deletePlayer(id: String): Boolean {
        writableDatabase.beginTransaction()
        return try {
            recordDeletions(writableDatabase, "players", "player", listOf(id))
            writableDatabase.execSQL("UPDATE event SET player_id=NULL WHERE player_id=?", arrayOf(id))
            val deleted = writableDatabase.delete("player", "id=?", arrayOf(id)) > 0
            writableDatabase.setTransactionSuccessful()
            deleted
        } finally { writableDatabase.endTransaction() }
    }
    fun addGame(title: String, home: String, away: String, scheduledAt: Long, videoQuality: String, periodCount: Int, periodDurationMs: Long): String = uuidV7().also { id -> writableDatabase.insertOrThrow("game", null, ContentValues().apply { put("id",id);put("title",title);put("home_id",home);put("away_id",away);put("status","READY");put("scheduled_at",scheduledAt);put("video_quality",videoQuality);put("period_count",periodCount);put("period_duration_ms",periodDurationMs);put("clock_remaining_ms",periodDurationMs);put("created_at",System.currentTimeMillis()) }) }

    // Newest first by creation time; legacy games keep random v4 ids, so ids never decide the order.
    fun games(): List<Game> = readableDatabase.rawQuery("SELECT g.id,g.title,g.home_id,g.away_id,h.name,a.name,g.home_score,g.away_score,g.status,g.scheduled_at,g.video_quality,g.period_count,g.period_duration_ms,g.current_period,g.clock_remaining_ms,g.owner_id FROM game g JOIN team h ON h.id=g.home_id JOIN team a ON a.id=g.away_id ORDER BY g.created_at DESC,g.id DESC",null).use { c -> buildList { while(c.moveToNext()) add(Game(c.getString(0),c.getString(1),c.getString(2),c.getString(3),c.getString(4),c.getString(5),c.getInt(6),c.getInt(7),c.getString(8),c.getLong(9),c.getString(10),c.getInt(11),c.getLong(12),c.getInt(13),c.getLong(14),c.getString(15))) } }
    fun deleteGame(id:String):Boolean{
        writableDatabase.beginTransaction()
        return try{
            recordDeletions(writableDatabase,"events","event",idsOf("SELECT id FROM event WHERE game_id=?",arrayOf(id)))
            recordDeletions(writableDatabase,"segments","segment",idsOf("SELECT id FROM segment WHERE game_id=?",arrayOf(id)))
            recordDeletions(writableDatabase,"games","game",listOf(id))
            writableDatabase.delete("event","game_id=?",arrayOf(id))
            writableDatabase.delete("segment","game_id=?",arrayOf(id))
            val deleted=writableDatabase.delete("game","id=?",arrayOf(id))>0
            writableDatabase.setTransactionSuccessful()
            deleted
        }finally{writableDatabase.endTransaction()}
    }
    fun status(id: String, value: String) = writableDatabase.update("game", ContentValues().apply { put("status",value) }, "id=?", arrayOf(id))
    fun videoQuality(id:String,value:String)=writableDatabase.update("game",ContentValues().apply{put("video_quality",value)},"id=?",arrayOf(id))
    fun saveProgress(id:String,period:Int,clockRemainingMs:Long)=writableDatabase.update("game",ContentValues().apply{put("current_period",period);put("clock_remaining_ms",clockRemainingMs)},"id=?",arrayOf(id))
    fun score(game: Game, homeDelta: Int, awayDelta: Int) { writableDatabase.execSQL("UPDATE game SET home_score=MAX(0,home_score+?), away_score=MAX(0,away_score+?) WHERE id=?", arrayOf<Any>(homeDelta,awayDelta,game.id)) }
    /** Keeps the persisted scoreboard in sync with the same active scoring events used by stats. */
    fun recalculateScore(gameId: String) {
        writableDatabase.execSQL("""
            UPDATE game
            SET home_score=COALESCE((SELECT SUM(value) FROM event WHERE game_id=? AND team_id=game.home_id AND reverted=0 AND (type LIKE 'PTS_%' OR type='FT_MADE' OR type='ADJ')),0),
                away_score=COALESCE((SELECT SUM(value) FROM event WHERE game_id=? AND team_id=game.away_id AND reverted=0 AND (type LIKE 'PTS_%' OR type='FT_MADE' OR type='ADJ')),0)
            WHERE id=?
        """.trimIndent(), arrayOf<Any>(gameId,gameId,gameId))
    }

    /** Rebuilds the denormalized game summary after a cloud merge. Events are the source of truth. */
    fun reconcileGameSummary(gameId: String) {
        recalculateScore(gameId)
        val game = games().firstOrNull { it.id == gameId } ?: return
        val latest = events(gameId).asSequence()
            .filter { !it.reverted && it.type != "STARTER" && it.type != "VIDEO" }
            .sortedWith(compareBy<StatEvent> { it.period }.thenByDescending { it.gameClockMs }.thenBy { it.id })
            .lastOrNull() ?: return
        if (latest.period > game.currentPeriod || (latest.period == game.currentPeriod && latest.gameClockMs < game.clockRemainingMs)) {
            saveProgress(gameId, latest.period, latest.gameClockMs)
        }
    }
    fun addEvent(gameId:String, teamId:String, playerId:String?, type:String, value:Int, period:Int, clock:Long, segment:Int, segmentMs:Long, videoMs:Long):String {
        val db=writableDatabase
        db.beginTransaction()
        return try {
            startSegment(gameId,segment)
            val id=uuidV7()
            db.insertOrThrow("event",null,ContentValues().apply { put("id",id);put("game_id",gameId);put("team_id",teamId);if(playerId!=null)put("player_id",playerId);put("type",type);put("value",value);put("period",period);put("game_clock_ms",clock);put("segment",segment);put("segment_time_ms",segmentMs);put("final_video_time_ms",videoMs);put("created_at",System.currentTimeMillis()) })
            db.setTransactionSuccessful()
            id
        } finally { db.endTransaction() }
    }
    fun undo(gameId:String): StatEvent? { val e=events(gameId).lastOrNull{!it.reverted}?:return null; writableDatabase.execSQL("UPDATE event SET reverted=1 WHERE id=?",arrayOf(e.id)); return e }
    fun revertEvent(id:String){writableDatabase.execSQL("UPDATE event SET reverted=1 WHERE id=?",arrayOf<Any>(id))}
    fun updateEvent(id:String,playerId:String?,type:String,value:Int,period:Int?=null,gameClockMs:Long?=null)=writableDatabase.update("event",ContentValues().apply{if(playerId==null)putNull("player_id") else put("player_id",playerId);put("type",type);put("value",value);period?.let{put("period",it)};gameClockMs?.let{put("game_clock_ms",it)}},"id=?",arrayOf(id))
    // Creation order: created_at first, then the time-ordered UUIDv7 for rows made in the same ms.
    fun events(gameId:String):List<StatEvent> = readableDatabase.rawQuery("SELECT id,game_id,team_id,player_id,type,value,period,game_clock_ms,segment,segment_time_ms,final_video_time_ms,reverted FROM event WHERE game_id=? ORDER BY created_at,id",arrayOf(gameId)).use { c -> buildList { while(c.moveToNext()) add(StatEvent(c.getString(0),c.getString(1),c.getString(2),if(c.isNull(3))null else c.getString(3),c.getString(4),c.getInt(5),c.getInt(6),c.getLong(7),c.getInt(8),c.getLong(9),c.getLong(10),c.getInt(11)!=0)) } }
    fun playerGameStats(gameId:String):Map<String,Pair<Long,Int>> = readableDatabase.rawQuery("SELECT player_id,minutes_ms,plus_minus FROM player_game_stat WHERE game_id=?",arrayOf(gameId)).use{c->buildMap{while(c.moveToNext())put(c.getString(0),c.getLong(1) to c.getInt(2))}}
    fun savePlayerGameStat(gameId:String,playerId:String,minutesMs:Long,plusMinus:Int){writableDatabase.insertWithOnConflict("player_game_stat",null,ContentValues().apply{put("game_id",gameId);put("player_id",playerId);put("minutes_ms",minutesMs);put("plus_minus",plusMinus)},SQLiteDatabase.CONFLICT_REPLACE)}
    fun recalculatePlayerGameStats(game:Game){
        val es=events(game.id).filterNot{it.reverted}.sortedWith(compareBy<StatEvent>{it.period}.thenByDescending{it.gameClockMs}.thenBy{it.id})
        // Only recorded STARTER events open a period for a player: a stat never implies that the
        // player was on the floor, so minutes come solely from STARTER / SUB_IN / SUB_OUT history.
        fun starters(teamId:String,period:Int):Set<String> =
            es.filter{it.teamId==teamId&&it.period==period&&it.type=="STARTER"}.mapNotNull{it.playerId}.distinct().take(5).toSet()
        // A completed game with one explicit five and no substitutions used the same lineup for
        // the whole game. Older builds sometimes wrote that lineup only when the period changed,
        // which made every starter's minutes and +/- cover only the final period. Reuse the
        // recorded five across all periods in this no-substitution case; games with substitutions
        // continue to use their period-specific STARTER / SUB_IN / SUB_OUT history.
        fun unchangedStartingFive(teamId:String):Set<String>?{
            if(es.any{it.teamId==teamId&&(it.type=="SUB_IN"||it.type=="SUB_OUT"||it.type=="SUBSTITUTION")})return null
            val recorded=es.filter{it.teamId==teamId&&it.type=="STARTER"}.mapNotNull{it.playerId}.distinct().take(5).toSet()
            return recorded.takeIf{game.status=="COMPLETED"&&it.size==5}
        }
        val minutes=mutableMapOf<String,Long>();val plusMinus=mutableMapOf<String,Int>()
        listOf(game.homeId,game.awayId).forEach{teamId->
            val fullGameFive=unchangedStartingFive(teamId)
            es.map{it.period}.distinct().forEach{period->
                val onCourt=(fullGameFive?:starters(teamId,period)).toMutableSet();val entered=onCourt.associateWith{game.periodDurationMs}.toMutableMap()
                es.filter{it.period==period}.forEach{e->
                    if(e.teamId==teamId&&e.type=="SUB_IN")e.playerId?.let{p->
                        val pairedClock=es.filter{candidate->candidate.type=="SUB_OUT"&&candidate.teamId==e.teamId&&candidate.period==e.period&&candidate.gameClockMs>=e.gameClockMs&&candidate.gameClockMs-e.gameClockMs<=5_000}
                            .minWithOrNull(compareBy<StatEvent>{it.gameClockMs}.thenBy{ kotlin.math.abs(es.indexOf(it)-es.indexOf(e)) })?.gameClockMs?:e.gameClockMs
                        onCourt+=p;entered.putIfAbsent(p,pairedClock)
                    }
                    else if(e.teamId==teamId&&e.type=="SUB_OUT")e.playerId?.let{p->entered.remove(p)?.let{start->minutes[p]=(minutes[p]?:0)+maxOf(0,start-e.gameClockMs)};onCourt-=p}
                    else if(e.type.startsWith("PTS_")||e.type=="FT_MADE"||e.type=="ADJ")onCourt.forEach{p->plusMinus[p]=(plusMinus[p]?:0)+(if(e.teamId==teamId)e.value else -e.value)}
                }
                entered.forEach{(p,start)->minutes[p]=(minutes[p]?:0)+maxOf(0,start)}
            }
        }
        val db=writableDatabase;db.beginTransaction();try{
            db.delete("player_game_stat","game_id=?",arrayOf(game.id))
            (players(game.homeId)+players(game.awayId)).forEach{p->savePlayerGameStat(game.id,p.id,minutes[p.id]?:0,plusMinus[p.id]?:0)}
            db.setTransactionSuccessful()
        }finally{db.endTransaction()}
    }
    fun startSegment(gameId:String, sequence:Int):String {
        readableDatabase.rawQuery("SELECT id FROM segment WHERE game_id=? AND sequence=? LIMIT 1",arrayOf(gameId,sequence.toString())).use { if(it.moveToFirst())return it.getString(0) }
        return uuidV7().also { id -> writableDatabase.insertOrThrow("segment",null,ContentValues().apply { put("id",id);put("game_id",gameId);put("sequence",sequence);put("uri","");put("created_at",System.currentTimeMillis()) }) }
    }
    fun finalizeSegment(id:String, uri:String, durationMs:Long) = writableDatabase.update("segment",ContentValues().apply { put("uri",uri);put("duration_ms",durationMs) },"id=?",arrayOf(id))
    /**
     * The game's recordings. A uri synced from someone else's row is never this phone's file (an
     * editor of a shared game could point it anywhere), so only own rows carry one; see [localRecordingUri].
     */
    fun segments(gameId:String):List<VideoSegment> = readableDatabase.rawQuery("SELECT sequence,CASE WHEN owner_id IS NULL THEN uri ELSE '' END,duration_ms FROM segment WHERE game_id=? ORDER BY sequence",arrayOf(gameId)).use { c -> buildList { while(c.moveToNext()) add(VideoSegment(c.getInt(0),c.getString(1),c.getLong(2))) } }

    /** Segments whose recording never finalized (a crash mid-recording leaves the uri empty). */
    fun orphanSegments(gameId:String):List<Pair<String,Int>> = readableDatabase.rawQuery("SELECT id,sequence FROM segment WHERE game_id=? AND uri='' AND owner_id IS NULL",arrayOf(gameId)).use { c -> buildList { while(c.moveToNext()) add(c.getString(0) to c.getInt(1)) } }

    /** Serializes one game so it can be re-imported on another device or as a new game. */
    fun exportGameJson(game:Game):JSONObject{
        fun rosterJson(teamId:String)=JSONArray().apply{players(teamId).forEach{put(JSONObject().put("number",it.number).put("name",it.name))}}
        val numbers=(players(game.homeId)+players(game.awayId)).associate{it.id to it}
        return JSONObject().apply{
            put("kind",GAME_EXPORT_KIND)
            put("schemaVersion",1)
            put("exportedAt",System.currentTimeMillis())
            put("game",JSONObject().apply{
                put("title",game.title);put("status",game.status);put("scheduledAt",game.scheduledAt);put("videoQuality",game.videoQuality)
                put("periodCount",game.periodCount);put("periodDurationMs",game.periodDurationMs)
                put("currentPeriod",game.currentPeriod);put("clockRemainingMs",game.clockRemainingMs)
                put("homeScore",game.homeScore);put("awayScore",game.awayScore)
            })
            put("home",JSONObject().put("name",game.homeName).put("players",rosterJson(game.homeId)))
            put("away",JSONObject().put("name",game.awayName).put("players",rosterJson(game.awayId)))
            put("events",JSONArray().apply{
                events(game.id).forEach{event->
                    val player=event.playerId?.let(numbers::get)
                    put(JSONObject().apply{
                        put("side",if(event.teamId==game.homeId)"HOME" else "AWAY")
                        put("playerNumber",player?.number?:"");put("playerName",player?.name?:"")
                        put("type",event.type);put("value",event.value)
                        put("period",event.period);put("gameClockMs",event.gameClockMs)
                        put("segment",event.segment);put("segmentTimeMs",event.segmentTimeMs);put("finalVideoTimeMs",event.finalVideoTimeMs)
                        put("reverted",event.reverted)
                    })
                }
            })
        }
    }

    /**
     * Recreates an exported game as a new game. Teams are matched by name and players by jersey number
     * (falling back to name for unnumbered players); anything missing is created. Video timestamps are
     * dropped because the imported stats do not belong to the new game's recording.
     */
    fun importGameJson(snapshot:JSONObject):GameImport{
        require(snapshot.optString("kind")==GAME_EXPORT_KIND){t("Not a HoopReplay game export")}
        val meta=snapshot.optJSONObject("game")?:JSONObject()
        val db=writableDatabase
        db.beginTransaction()
        try{
            var createdTeams=0
            var createdPlayers=0
            fun resolveTeam(side:JSONObject):String{
                val name=side.optString("name").trim().ifBlank{"Unnamed"}.capitalizeInitial()
                val existing=teams().firstOrNull{it.name.equals(name,true)}
                val teamId=existing?.id?:addTeam(name).also{createdTeams++}
                val roster=side.optJSONArray("players")?:JSONArray()
                for(index in 0 until roster.length()){
                    val entry=roster.getJSONObject(index)
                    val number=entry.optString("number").trim()
                    val playerName=entry.optString("name").trim()
                    if(number.isBlank()&&playerName.isBlank())continue
                    if(findPlayer(teamId,playerName,number)==null){addPlayer(teamId,playerName,number);createdPlayers++}
                }
                return teamId
            }
            val home=snapshot.optJSONObject("home")?:JSONObject()
            val away=snapshot.optJSONObject("away")?:JSONObject()
            val homeId=resolveTeam(home)
            val awayId=resolveTeam(away)
            val periodDurationMs=meta.optLong("periodDurationMs",480_000L)
            val gameId=addGame(
                meta.optString("title").ifBlank{"Imported game"},
                homeId,awayId,
                meta.optLong("scheduledAt",System.currentTimeMillis()),
                meta.optString("videoQuality").ifBlank{"HIGHEST"},
                meta.optInt("periodCount",4),
                periodDurationMs
            )
            db.update("game",ContentValues().apply{
                put("home_score",meta.optInt("homeScore"));put("away_score",meta.optInt("awayScore"))
                put("status",meta.optString("status").ifBlank{"READY"})
                put("current_period",meta.optInt("currentPeriod",1))
                put("clock_remaining_ms",meta.optLong("clockRemainingMs",periodDurationMs))
            },"id=?",arrayOf(gameId))
            val events=snapshot.optJSONArray("events")?:JSONArray()
            // Imported plays reference recording 0, which the cloud requires to exist.
            startSegment(gameId,0)
            val importedAt=System.currentTimeMillis()
            var importedEvents=0
            for(index in 0 until events.length()){
                val event=events.getJSONObject(index)
                val teamId=if(event.optString("side")=="AWAY")awayId else homeId
                val number=event.optString("playerNumber").trim()
                val playerName=event.optString("playerName").trim()
                val playerId=if(number.isBlank()&&playerName.isBlank())null else findPlayer(teamId,playerName,number)?.id
                    ?:addPlayer(teamId,playerName,number).also{createdPlayers++}
                db.insertOrThrow("event",null,ContentValues().apply{
                    put("id",uuidV7())
                    put("game_id",gameId);put("team_id",teamId);if(playerId!=null)put("player_id",playerId)
                    put("type",event.optString("type"));put("value",event.optInt("value"))
                    put("period",event.optInt("period",1));put("game_clock_ms",event.optLong("gameClockMs"))
                    put("segment",0);put("segment_time_ms",0);put("final_video_time_ms",0)
                    put("reverted",if(event.optBoolean("reverted"))1 else 0)
                    put("created_at",importedAt+index)
                })
                importedEvents++
            }
            db.setTransactionSuccessful()
            return GameImport(gameId,importedEvents,createdTeams,createdPlayers)
        }finally{db.endTransaction()}
    }

    /**
     * The rows this account may push: its own rows, and only those whose parents are its own too.
     * A shared game is a read-only copy here, so a play recorded into it stays on this phone.
     */
    fun exportSyncSnapshot():JSONObject=JSONObject().apply{
        val ownTeam="SELECT id FROM team WHERE owner_id IS NULL"
        val ownGame="SELECT id FROM game WHERE owner_id IS NULL AND home_id IN ($ownTeam) AND away_id IN ($ownTeam)"
        put("teams",queryJson("SELECT id,name,created_at FROM team WHERE owner_id IS NULL ORDER BY id",arrayOf("id","name","created_at")))
        put("players",queryJson("SELECT id,team_id,name,number FROM player WHERE owner_id IS NULL AND team_id IN ($ownTeam) ORDER BY id",arrayOf("id","team_id","name","number")))
        put("games",queryJson("SELECT id,title,home_id,away_id,home_score,away_score,status,scheduled_at,video_quality,period_count,period_duration_ms,current_period,clock_remaining_ms,created_at FROM game WHERE id IN ($ownGame) ORDER BY id",arrayOf("id","title","home_id","away_id","home_score","away_score","status","scheduled_at","video_quality","period_count","period_duration_ms","current_period","clock_remaining_ms","created_at")))
        put("segments",queryJson("SELECT id,game_id,sequence,uri,duration_ms,created_at FROM segment WHERE owner_id IS NULL AND game_id IN ($ownGame) ORDER BY id",arrayOf("id","game_id","sequence","uri","duration_ms","created_at")))
        put("events",queryJson("SELECT id,game_id,team_id,player_id,type,value,period,game_clock_ms,segment,segment_time_ms,final_video_time_ms,reverted,created_at FROM event WHERE owner_id IS NULL AND game_id IN ($ownGame) AND team_id IN ($ownTeam) AND (player_id IS NULL OR player_id IN (SELECT id FROM player WHERE owner_id IS NULL)) ORDER BY id",arrayOf("id","game_id","team_id","player_id","type","value","period","game_clock_ms","segment","segment_time_ms","final_video_time_ms","reverted","created_at")))
    }

    private fun queryJson(sql:String,columns:Array<String>):JSONArray=readableDatabase.rawQuery(sql,null).use{cursor->JSONArray().apply{while(cursor.moveToNext()){put(JSONObject().apply{columns.forEachIndexed{index,column->if(cursor.isNull(index))put(column,JSONObject.NULL)else when(cursor.getType(index)){android.database.Cursor.FIELD_TYPE_INTEGER->put(column,cursor.getLong(index));android.database.Cursor.FIELD_TYPE_FLOAT->put(column,cursor.getDouble(index));else->put(column,cursor.getString(index))}}})}}}

    /**
     * Merges a pull. Rows carry `owner_id` (absent for this account's own rows) and `sync_space`.
     * A shared row the pull no longer returned was unshared or deleted, so its copy goes too.
     */
    fun mergeSyncSnapshot(snapshot:JSONObject){
        val db=writableDatabase
        db.beginTransaction()
        try{
            val owned=arrayOf("owner_id","sync_space")
            mergeRows(db,"team",snapshot.optJSONArray("teams"),arrayOf("id","name","created_at")+owned)
            mergeRows(db,"player",snapshot.optJSONArray("players"),arrayOf("id","team_id","name","number")+owned)
            mergeRows(db,"game",snapshot.optJSONArray("games"),arrayOf("id","title","home_id","away_id","home_score","away_score","status","scheduled_at","video_quality","period_count","period_duration_ms","current_period","clock_remaining_ms","created_at")+owned)
            mergeRows(db,"segment",snapshot.optJSONArray("segments"),arrayOf("id","game_id","sequence","uri","duration_ms","created_at")+owned)
            mergeRows(db,"event",snapshot.optJSONArray("events"),arrayOf("id","game_id","team_id","player_id","type","value","period","game_clock_ms","segment","segment_time_ms","final_video_time_ms","reverted","created_at")+owned)
            DELETABLE_ENTITIES.forEach{(entity,table)->
                val pulled=(snapshot.optJSONArray(entity)?:JSONArray()).let{rows->(0 until rows.length()).map{rows.getJSONObject(it).optString("id")}.toSet()}
                idsOf("SELECT id FROM $table WHERE owner_id IS NOT NULL",emptyArray()).filterNot(pulled::contains).forEach{db.delete(table,"id=?",arrayOf(it))}
            }
            // The cloud game row can lag behind its event rows. Reconcile after all dependent rows
            // are present so Download cannot reintroduce an old 0:0 score or opening clock.
            val mergedGameIds = (snapshot.optJSONArray("games") ?: JSONArray()).let { rows ->
                (0 until rows.length()).map { rows.getJSONObject(it).optString("id") }
            }
            mergedGameIds.forEach { reconcileGameSummary(it) }
            mergeRows(db,"deletion",snapshot.optJSONArray("deletions"),arrayOf("entity","row_id","deleted_at","device_id"))
            applyDeletions(db)
            db.setTransactionSuccessful()
        }finally{db.endTransaction()}
    }

    /** Replays every tombstone this device knows about, so a game deleted elsewhere disappears here too. Ids are never reused, so a tombstone always wins. */
    private fun applyDeletions(db:SQLiteDatabase){
        DELETABLE_ENTITIES.forEach{(entity,table)->
            db.execSQL("DELETE FROM $table WHERE id IN (SELECT row_id FROM deletion WHERE entity=?)",arrayOf<Any>(entity))
        }
    }

    /** Tombstones this device still has to push, newest last. */
    fun pendingDeletions():JSONArray=queryJson("SELECT entity,row_id,deleted_at,device_id FROM deletion WHERE row_id NOT LIKE '$LEGACY%' ORDER BY deleted_at",arrayOf("entity","row_id","deleted_at","device_id"))

    /** Replaces rows by id. A shared row never replaces one of this account's own rows. */
    private fun mergeRows(db:SQLiteDatabase,table:String,rows:JSONArray?,columns:Array<String>){
        if(rows==null)return
        for(index in 0 until rows.length()){
            val row=rows.getJSONObject(index)
            if(table!="deletion"&&row.has("owner_id")&&!row.isNull("owner_id")&&
                db.rawQuery("SELECT 1 FROM $table WHERE id=? AND owner_id IS NULL",arrayOf(row.optString("id"))).use{it.moveToFirst()})continue
            val values=ContentValues()
            columns.forEach{column->if(row.has(column)&&!row.isNull(column)){val value=row.get(column);when(value){is Number->values.put(column,value.toLong());else->values.put(column,value.toString())}}}
            db.insertWithOnConflict(table,null,values,SQLiteDatabase.CONFLICT_REPLACE)
        }
    }

    /** True while rows from before the uuid upgrade still carry `legacy:<n>` placeholder ids. */
    fun hasLegacyIds():Boolean=ENTITY_COLUMNS.values.flatten().any{(table,column)->
        readableDatabase.rawQuery("SELECT 1 FROM $table WHERE $column LIKE '$LEGACY%' LIMIT 1",null).use{it.moveToFirst()}
    } || readableDatabase.rawQuery("SELECT 1 FROM deletion WHERE row_id LIKE '$LEGACY%' LIMIT 1",null).use{it.moveToFirst()}

    /**
     * One-time switch of `legacy:<n>` placeholders to the server's uuids (contract rule 6b), in one
     * transaction: [mapping] is entity → legacy number → uuid of this account's rows, [tombstones]
     * entity → legacy numbers the cloud deleted. Rows the cloud deleted go; a placeholder the cloud
     * never saw gets a fresh UUIDv7; a legacy tombstone without a mapping is dropped.
     */
    fun adoptLegacyIds(mapping:Map<String,Map<Long,String>>,tombstones:Map<String,Set<Long>>){
        val db=writableDatabase
        db.beginTransaction()
        try{
            db.execSQL("CREATE TEMP TABLE IF NOT EXISTS legacy_map(entity TEXT NOT NULL, old TEXT NOT NULL, new TEXT NOT NULL, PRIMARY KEY(entity, old))")
            db.execSQL("DELETE FROM legacy_map")
            fun map(entity:String,old:String,new:String)=db.insertWithOnConflict("legacy_map",null,ContentValues().apply{put("entity",entity);put("old",old);put("new",new)},SQLiteDatabase.CONFLICT_IGNORE)
            mapping.forEach{(entity,rows)->rows.forEach{(legacy,uuid)->map(entity,LEGACY+legacy,uuid)}}
            tombstones.forEach{(entity,numbers)->
                val table=DELETABLE_ENTITIES.firstOrNull{it.first==entity}?.second?:return@forEach
                numbers.forEach{db.delete(table,"id=?",arrayOf(LEGACY+it))}
            }
            // Local tombstones follow their row's server id; one the server never knew is meaningless.
            db.execSQL("UPDATE deletion SET row_id=(SELECT new FROM legacy_map m WHERE m.entity=deletion.entity AND m.old=deletion.row_id) WHERE row_id IN (SELECT old FROM legacy_map m WHERE m.entity=deletion.entity)")
            db.execSQL("DELETE FROM deletion WHERE row_id LIKE '$LEGACY%'")
            ENTITY_COLUMNS.forEach{(entity,columns)->
                columns.forEach{(table,column)->
                    idsOf("SELECT DISTINCT $column FROM $table WHERE $column LIKE '$LEGACY%'",emptyArray()).forEach{map(entity,it,uuidV7(legacyTime(it)))}
                }
                columns.forEach{(table,column)->
                    db.execSQL("UPDATE $table SET $column=(SELECT new FROM legacy_map m WHERE m.entity=? AND m.old=$table.$column) WHERE $column LIKE '$LEGACY%'",arrayOf<Any>(entity))
                }
            }
            db.execSQL("DELETE FROM legacy_map")
            db.setTransactionSuccessful()
        }finally{db.endTransaction()}
    }

    /** Removes every synced row and tombstone, so the next account on this phone starts empty. */
    fun wipe(){
        val db=writableDatabase
        db.beginTransaction()
        try{
            TABLES.keys.forEach{db.delete(it,null,null)}
            db.setTransactionSuccessful()
        }finally{db.endTransaction()}
    }
}
