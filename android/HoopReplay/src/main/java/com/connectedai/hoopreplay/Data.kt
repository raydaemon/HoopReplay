package com.connectedai.hoopreplay

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject

data class Team(val id: Long, val name: String)
data class Player(val id: Long, val teamId: Long, val name: String, val number: String) {
    /** "#12 Haoxuan Tan"; a player without a jersey number shows only the name, never "#--". */
    val label: String get() = if (number.isBlank()) name.trim() else "#${number.trim()} ${name.trim()}".trim()
}
data class Game(val id: Long, val title: String, val homeId: Long, val awayId: Long, val homeName: String, val awayName: String, val homeScore: Int, val awayScore: Int, val status: String, val scheduledAt: Long, val videoQuality: String, val periodCount: Int, val periodDurationMs: Long, val currentPeriod: Int, val clockRemainingMs: Long)
data class GameImport(val gameId: Long, val events: Int, val createdTeams: Int, val createdPlayers: Int)
data class StatEvent(val id: Long, val gameId: Long, val teamId: Long, val playerId: Long?, val type: String, val value: Int, val period: Int, val gameClockMs: Long, val segment: Int, val segmentTimeMs: Long, val finalVideoTimeMs: Long, val reverted: Boolean)

private const val GAME_EXPORT_KIND = "hoopreplay.game"
private const val DELETION_TABLE = "CREATE TABLE IF NOT EXISTS deletion(entity TEXT NOT NULL, local_id INTEGER NOT NULL, deleted_at INTEGER NOT NULL, device_id TEXT NOT NULL, PRIMARY KEY(entity, local_id))"
private const val ID_SALT_RANGE = 1000L
private val DELETABLE_ENTITIES = listOf("teams" to "team", "players" to "player", "games" to "game", "events" to "event", "segments" to "segment")

internal fun String.capitalizeInitial(): String {
    val firstLetter = indexOfFirst(Char::isLetter)
    if (firstLetter == -1) return this
    return replaceRange(firstLetter, firstLetter + 1, this[firstLetter].titlecase())
}

class HoopDb(private val context: Context) : SQLiteOpenHelper(context, "hoopreplay.db", null, 9) {
    private var lastIdTick = 0L

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE team(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE player(id INTEGER PRIMARY KEY, team_id INTEGER NOT NULL, name TEXT NOT NULL, number TEXT NOT NULL)")
        db.execSQL("CREATE TABLE game(id INTEGER PRIMARY KEY, title TEXT NOT NULL, home_id INTEGER NOT NULL, away_id INTEGER NOT NULL, home_score INTEGER NOT NULL DEFAULT 0, away_score INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, scheduled_at INTEGER NOT NULL, video_quality TEXT NOT NULL DEFAULT 'HIGHEST', period_count INTEGER NOT NULL DEFAULT 4, period_duration_ms INTEGER NOT NULL DEFAULT 480000, current_period INTEGER NOT NULL DEFAULT 1, clock_remaining_ms INTEGER NOT NULL DEFAULT 480000, created_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE event(id INTEGER PRIMARY KEY, game_id INTEGER NOT NULL, team_id INTEGER NOT NULL, player_id INTEGER, type TEXT NOT NULL, value INTEGER NOT NULL, period INTEGER NOT NULL, game_clock_ms INTEGER NOT NULL, segment INTEGER NOT NULL, segment_time_ms INTEGER NOT NULL, final_video_time_ms INTEGER NOT NULL, reverted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE player_game_stat(game_id INTEGER NOT NULL, player_id INTEGER NOT NULL, minutes_ms INTEGER NOT NULL DEFAULT 0, plus_minus INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(game_id,player_id))")
        db.execSQL("CREATE TABLE segment(id INTEGER PRIMARY KEY, game_id INTEGER NOT NULL, sequence INTEGER NOT NULL, uri TEXT NOT NULL, duration_ms INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)")
        db.execSQL(DELETION_TABLE)
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
        if (oldVersion < 6) db.execSQL(DELETION_TABLE)
        // An older build wrote rebounds as "REBOUND"; the server only accepts "REB", so those rows
        // failed to sync with an event_type_check violation until they are normalized here.
        if (oldVersion < 7) db.execSQL("UPDATE event SET type='REB' WHERE type='REBOUND'")
        if (oldVersion < 8) db.execSQL("CREATE TABLE player_game_stat(game_id INTEGER NOT NULL, player_id INTEGER NOT NULL, minutes_ms INTEGER NOT NULL DEFAULT 0, plus_minus INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(game_id,player_id))")
        // Older Android builds stored the display-only alias FOULED; the cloud accepts FOUL_DRAWN.
        if (oldVersion < 9) db.execSQL("UPDATE event SET type='FOUL_DRAWN' WHERE type='FOULED'")
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
    private fun recordDeletions(db: SQLiteDatabase, entity: String, ids: List<Long>) {
        if (ids.isEmpty()) return
        val deletedAt = System.currentTimeMillis()
        val device = deviceId()
        ids.forEach { id ->
            db.insertWithOnConflict("deletion", null, ContentValues().apply {
                put("entity", entity); put("local_id", id); put("deleted_at", deletedAt); put("device_id", device)
            }, SQLiteDatabase.CONFLICT_REPLACE)
        }
    }
    /** SQLite hands out deleted row ids again, so a reused id must drop the tombstone it inherited. */
    private fun clearDeletion(entity: String, id: Long) {
        writableDatabase.delete("deletion", "entity=? AND local_id=?", arrayOf(entity, id.toString()))
    }
    /**
     * Allocates the id for a new row.
     *
     * SQLite's own rowid is `max(existing) + 1`, which is only unique on this device: another
     * device that loaded the same data picks the same number for a different row, and whichever
     * syncs last silently replaces the other's work. Deriving the id from the clock and a
     * per-device salt keeps each device in its own lane while ids stay sortable by creation order.
     */
    @Synchronized
    private fun nextLocalId(table: String, entity: String): Long {
        val highest = readableDatabase.rawQuery(
            "SELECT MAX(value) FROM (SELECT COALESCE(MAX(id),0) AS value FROM $table UNION ALL SELECT COALESCE(MAX(local_id),0) FROM deletion WHERE entity=?)",
            arrayOf(entity)
        ).use { if (it.moveToFirst()) it.getLong(0) else 0L }
        val tick = maxOf(System.currentTimeMillis(), highest / ID_SALT_RANGE + 1, lastIdTick + 1)
        lastIdTick = tick
        return tick * ID_SALT_RANGE + deviceSalt()
    }
    private fun deviceSalt(): Long {
        val id = deviceId()
        var hash = 0L
        id.forEach { hash = (hash * 31 + it.code) % ID_SALT_RANGE }
        return hash
    }
    private fun idsOf(sql: String, args: Array<String>): List<Long> =
        readableDatabase.rawQuery(sql, args).use { c -> buildList { while (c.moveToNext()) add(c.getLong(0)) } }

    fun addTeam(name: String): Long = writableDatabase.insert("team", null, ContentValues().apply { put("id", nextLocalId("team", "teams")); put("name", name.capitalizeInitial()); put("created_at", System.currentTimeMillis()) }).also { clearDeletion("teams", it) }
    fun teams(): List<Team> = readableDatabase.rawQuery("SELECT id,name FROM team ORDER BY id", null).use { c -> buildList { while(c.moveToNext()) add(Team(c.getLong(0), c.getString(1))) } }
    fun deleteTeam(id: Long): Boolean {
        val inUse = readableDatabase.rawQuery("SELECT 1 FROM game WHERE home_id=? OR away_id=? LIMIT 1", arrayOf(id.toString(), id.toString())).use { it.moveToFirst() }
        if (inUse) return false
        writableDatabase.beginTransaction()
        return try {
            recordDeletions(writableDatabase, "players", idsOf("SELECT id FROM player WHERE team_id=?", arrayOf(id.toString())))
            recordDeletions(writableDatabase, "teams", listOf(id))
            writableDatabase.delete("player", "team_id=?", arrayOf(id.toString()))
            val deleted = writableDatabase.delete("team", "id=?", arrayOf(id.toString())) > 0
            writableDatabase.setTransactionSuccessful()
            deleted
        } finally { writableDatabase.endTransaction() }
    }
    fun findPlayer(team: Long, name: String, number: String): Player? {
        val cleanName = name.capitalizeInitial().trim()
        val cleanNumber = number.trim()
        val roster = players(team)
        return if (cleanNumber.isNotBlank()) roster.firstOrNull { it.number.trim() == cleanNumber }
        else roster.firstOrNull { it.number.isBlank() && cleanName.isNotBlank() && it.name.equals(cleanName, true) }
    }
    /** Reuses the existing player when the jersey number (or the name, for unnumbered players) already exists on the team. */
    fun addPlayer(team: Long, name: String, number: String): Long =
        findPlayer(team, name, number)?.id
            ?: writableDatabase.insert("player", null, ContentValues().apply { put("id", nextLocalId("player", "players")); put("team_id", team); put("name", name.capitalizeInitial()); put("number", number) }).also { clearDeletion("players", it) }
    fun players(team: Long): List<Player> = readableDatabase.rawQuery("SELECT id,team_id,name,number FROM player WHERE team_id=? ORDER BY CAST(number AS INTEGER)", arrayOf(team.toString())).use { c -> buildList { while(c.moveToNext()) add(Player(c.getLong(0),c.getLong(1),c.getString(2),c.getString(3))) } }
    /** Renames a player / changes their jersey number in place, so recorded stats stay attached. */
    fun updatePlayer(id: Long, name: String, number: String) =
        writableDatabase.update("player", ContentValues().apply { put("name", name.trim().capitalizeInitial()); put("number", number.trim()) }, "id=?", arrayOf(id.toString()))
    fun playerHasEvents(id: Long): Boolean = readableDatabase.rawQuery("SELECT 1 FROM event WHERE player_id=? LIMIT 1", arrayOf(id.toString())).use { it.moveToNext() }
    fun deletePlayer(id: Long): Boolean {
        writableDatabase.beginTransaction()
        return try {
            recordDeletions(writableDatabase, "players", listOf(id))
            writableDatabase.execSQL("UPDATE event SET player_id=NULL WHERE player_id=?", arrayOf(id))
            val deleted = writableDatabase.delete("player", "id=?", arrayOf(id.toString())) > 0
            writableDatabase.setTransactionSuccessful()
            deleted
        } finally { writableDatabase.endTransaction() }
    }
    fun addGame(title: String, home: Long, away: Long, scheduledAt: Long, videoQuality: String, periodCount: Int, periodDurationMs: Long): Long = writableDatabase.insert("game", null, ContentValues().apply { put("id",nextLocalId("game","games"));put("title",title);put("home_id",home);put("away_id",away);put("status","READY");put("scheduled_at",scheduledAt);put("video_quality",videoQuality);put("period_count",periodCount);put("period_duration_ms",periodDurationMs);put("clock_remaining_ms",periodDurationMs);put("created_at",System.currentTimeMillis()) }).also { clearDeletion("games", it) }

    fun games(): List<Game> = readableDatabase.rawQuery("SELECT g.id,g.title,g.home_id,g.away_id,h.name,a.name,g.home_score,g.away_score,g.status,g.scheduled_at,g.video_quality,g.period_count,g.period_duration_ms,g.current_period,g.clock_remaining_ms FROM game g JOIN team h ON h.id=g.home_id JOIN team a ON a.id=g.away_id ORDER BY g.id DESC",null).use { c -> buildList { while(c.moveToNext()) add(Game(c.getLong(0),c.getString(1),c.getLong(2),c.getLong(3),c.getString(4),c.getString(5),c.getInt(6),c.getInt(7),c.getString(8),c.getLong(9),c.getString(10),c.getInt(11),c.getLong(12),c.getInt(13),c.getLong(14))) } }
    fun deleteGame(id:Long):Boolean{
        writableDatabase.beginTransaction()
        return try{
            recordDeletions(writableDatabase,"events",idsOf("SELECT id FROM event WHERE game_id=?",arrayOf(id.toString())))
            recordDeletions(writableDatabase,"segments",idsOf("SELECT id FROM segment WHERE game_id=?",arrayOf(id.toString())))
            recordDeletions(writableDatabase,"games",listOf(id))
            writableDatabase.delete("event","game_id=?",arrayOf(id.toString()))
            writableDatabase.delete("segment","game_id=?",arrayOf(id.toString()))
            val deleted=writableDatabase.delete("game","id=?",arrayOf(id.toString()))>0
            writableDatabase.setTransactionSuccessful()
            deleted
        }finally{writableDatabase.endTransaction()}
    }
    fun status(id: Long, value: String) = writableDatabase.update("game", ContentValues().apply { put("status",value) }, "id=?", arrayOf(id.toString()))
    fun videoQuality(id:Long,value:String)=writableDatabase.update("game",ContentValues().apply{put("video_quality",value)},"id=?",arrayOf(id.toString()))
    fun saveProgress(id:Long,period:Int,clockRemainingMs:Long)=writableDatabase.update("game",ContentValues().apply{put("current_period",period);put("clock_remaining_ms",clockRemainingMs)},"id=?",arrayOf(id.toString()))
    fun score(game: Game, homeDelta: Int, awayDelta: Int) { writableDatabase.execSQL("UPDATE game SET home_score=MAX(0,home_score+?), away_score=MAX(0,away_score+?) WHERE id=?", arrayOf<Any>(homeDelta,awayDelta,game.id)) }
    /** Keeps the persisted scoreboard in sync with the same active scoring events used by stats. */
    fun recalculateScore(gameId: Long) {
        writableDatabase.execSQL("""
            UPDATE game
            SET home_score=COALESCE((SELECT SUM(value) FROM event WHERE game_id=? AND team_id=game.home_id AND reverted=0 AND (type LIKE 'PTS_%' OR type='FT_MADE' OR type='ADJ')),0),
                away_score=COALESCE((SELECT SUM(value) FROM event WHERE game_id=? AND team_id=game.away_id AND reverted=0 AND (type LIKE 'PTS_%' OR type='FT_MADE' OR type='ADJ')),0)
            WHERE id=?
        """.trimIndent(), arrayOf<Any>(gameId,gameId,gameId))
    }

    /** Rebuilds the denormalized game summary after a cloud merge. Events are the source of truth. */
    fun reconcileGameSummary(gameId: Long) {
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
    fun addEvent(gameId:Long, teamId:Long, playerId:Long?, type:String, value:Int, period:Int, clock:Long, segment:Int, segmentMs:Long, videoMs:Long):Long {
        val db=writableDatabase
        db.beginTransaction()
        return try {
            startSegment(gameId,segment)
            val id=db.insertOrThrow("event",null,ContentValues().apply { put("id",nextLocalId("event","events"));put("game_id",gameId);put("team_id",teamId);if(playerId!=null)put("player_id",playerId);put("type",type);put("value",value);put("period",period);put("game_clock_ms",clock);put("segment",segment);put("segment_time_ms",segmentMs);put("final_video_time_ms",videoMs);put("created_at",System.currentTimeMillis()) })
            db.delete("deletion","entity=? AND local_id=?",arrayOf("events",id.toString()))
            db.setTransactionSuccessful()
            id
        } finally { db.endTransaction() }
    }
    fun undo(gameId:Long): StatEvent? { val e=events(gameId).lastOrNull{!it.reverted}?:return null; writableDatabase.execSQL("UPDATE event SET reverted=1 WHERE id=?",arrayOf(e.id)); return e }
    fun revertEvent(id:Long){writableDatabase.execSQL("UPDATE event SET reverted=1 WHERE id=?",arrayOf<Any>(id))}
    fun updateEvent(id:Long,playerId:Long?,type:String,value:Int,period:Int?=null,gameClockMs:Long?=null)=writableDatabase.update("event",ContentValues().apply{if(playerId==null)putNull("player_id") else put("player_id",playerId);put("type",type);put("value",value);period?.let{put("period",it)};gameClockMs?.let{put("game_clock_ms",it)}},"id=?",arrayOf(id.toString()))
    fun events(gameId:Long):List<StatEvent> = readableDatabase.rawQuery("SELECT id,game_id,team_id,player_id,type,value,period,game_clock_ms,segment,segment_time_ms,final_video_time_ms,reverted FROM event WHERE game_id=? ORDER BY id",arrayOf(gameId.toString())).use { c -> buildList { while(c.moveToNext()) add(StatEvent(c.getLong(0),c.getLong(1),c.getLong(2),if(c.isNull(3))null else c.getLong(3),c.getString(4),c.getInt(5),c.getInt(6),c.getLong(7),c.getInt(8),c.getLong(9),c.getLong(10),c.getInt(11)!=0)) } }
    fun playerGameStats(gameId:Long):Map<Long,Pair<Long,Int>> = readableDatabase.rawQuery("SELECT player_id,minutes_ms,plus_minus FROM player_game_stat WHERE game_id=?",arrayOf(gameId.toString())).use{c->buildMap{while(c.moveToNext())put(c.getLong(0),c.getLong(1) to c.getInt(2))}}
    fun savePlayerGameStat(gameId:Long,playerId:Long,minutesMs:Long,plusMinus:Int){writableDatabase.insertWithOnConflict("player_game_stat",null,ContentValues().apply{put("game_id",gameId);put("player_id",playerId);put("minutes_ms",minutesMs);put("plus_minus",plusMinus)},SQLiteDatabase.CONFLICT_REPLACE)}
    fun recalculatePlayerGameStats(game:Game){
        val es=events(game.id).filterNot{it.reverted}.sortedWith(compareBy<StatEvent>{it.period}.thenByDescending{it.gameClockMs}.thenBy{it.id})
        // Only recorded STARTER events open a period for a player: a stat never implies that the
        // player was on the floor, so minutes come solely from STARTER / SUB_IN / SUB_OUT history.
        fun starters(teamId:Long,period:Int):Set<Long> =
            es.filter{it.teamId==teamId&&it.period==period&&it.type=="STARTER"}.mapNotNull{it.playerId}.distinct().take(5).toSet()
        // A completed game with one explicit five and no substitutions used the same lineup for
        // the whole game. Older builds sometimes wrote that lineup only when the period changed,
        // which made every starter's minutes and +/- cover only the final period. Reuse the
        // recorded five across all periods in this no-substitution case; games with substitutions
        // continue to use their period-specific STARTER / SUB_IN / SUB_OUT history.
        fun unchangedStartingFive(teamId:Long):Set<Long>?{
            if(es.any{it.teamId==teamId&&(it.type=="SUB_IN"||it.type=="SUB_OUT"||it.type=="SUBSTITUTION")})return null
            val recorded=es.filter{it.teamId==teamId&&it.type=="STARTER"}.mapNotNull{it.playerId}.distinct().take(5).toSet()
            return recorded.takeIf{game.status=="COMPLETED"&&it.size==5}
        }
        val minutes=mutableMapOf<Long,Long>();val plusMinus=mutableMapOf<Long,Int>()
        listOf(game.homeId,game.awayId).forEach{teamId->
            val fullGameFive=unchangedStartingFive(teamId)
            es.map{it.period}.distinct().forEach{period->
                val onCourt=(fullGameFive?:starters(teamId,period)).toMutableSet();val entered=onCourt.associateWith{game.periodDurationMs}.toMutableMap()
                es.filter{it.period==period}.forEach{e->
                    if(e.teamId==teamId&&e.type=="SUB_IN")e.playerId?.let{p->
                        val pairedClock=es.filter{candidate->candidate.type=="SUB_OUT"&&candidate.teamId==e.teamId&&candidate.period==e.period&&candidate.gameClockMs>=e.gameClockMs&&candidate.gameClockMs-e.gameClockMs<=5_000}
                            .minWithOrNull(compareBy<StatEvent>{it.gameClockMs}.thenBy{ kotlin.math.abs(it.id-e.id) })?.gameClockMs?:e.gameClockMs
                        onCourt+=p;entered.putIfAbsent(p,pairedClock)
                    }
                    else if(e.teamId==teamId&&e.type=="SUB_OUT")e.playerId?.let{p->entered.remove(p)?.let{start->minutes[p]=(minutes[p]?:0)+maxOf(0,start-e.gameClockMs)};onCourt-=p}
                    else if(e.type.startsWith("PTS_")||e.type=="FT_MADE"||e.type=="ADJ")onCourt.forEach{p->plusMinus[p]=(plusMinus[p]?:0)+(if(e.teamId==teamId)e.value else -e.value)}
                }
                entered.forEach{(p,start)->minutes[p]=(minutes[p]?:0)+maxOf(0,start)}
            }
        }
        val db=writableDatabase;db.beginTransaction();try{
            db.delete("player_game_stat","game_id=?",arrayOf(game.id.toString()))
            (players(game.homeId)+players(game.awayId)).forEach{p->savePlayerGameStat(game.id,p.id,minutes[p.id]?:0,plusMinus[p.id]?:0)}
            db.setTransactionSuccessful()
        }finally{db.endTransaction()}
    }
    fun startSegment(gameId:Long, sequence:Int):Long {
        readableDatabase.rawQuery("SELECT id FROM segment WHERE game_id=? AND sequence=? LIMIT 1",arrayOf(gameId.toString(),sequence.toString())).use { if(it.moveToFirst())return it.getLong(0) }
        return writableDatabase.insertOrThrow("segment",null,ContentValues().apply { put("id",nextLocalId("segment","segments"));put("game_id",gameId);put("sequence",sequence);put("uri","");put("created_at",System.currentTimeMillis()) }).also { clearDeletion("segments", it) }
    }
    fun finalizeSegment(id:Long, uri:String, durationMs:Long) = writableDatabase.update("segment",ContentValues().apply { put("uri",uri);put("duration_ms",durationMs) },"id=?",arrayOf(id.toString()))
    /** Segments whose recording never finalized (a crash mid-recording leaves the uri empty). */
    fun segments(gameId:Long):List<VideoSegment> = readableDatabase.rawQuery("SELECT sequence,uri,duration_ms FROM segment WHERE game_id=? ORDER BY sequence",arrayOf(gameId.toString())).use { c -> buildList { while(c.moveToNext()) add(VideoSegment(c.getInt(0),c.getString(1),c.getLong(2))) } }

    fun orphanSegments(gameId:Long):List<Pair<Long,Int>> = readableDatabase.rawQuery("SELECT id,sequence FROM segment WHERE game_id=? AND uri=''",arrayOf(gameId.toString())).use { c -> buildList { while(c.moveToNext()) add(c.getLong(0) to c.getInt(1)) } }

    /** Serializes one game so it can be re-imported on another device or as a new game. */
    fun exportGameJson(game:Game):JSONObject{
        fun rosterJson(teamId:Long)=JSONArray().apply{players(teamId).forEach{put(JSONObject().put("number",it.number).put("name",it.name))}}
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
            fun resolveTeam(side:JSONObject):Long{
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
            },"id=?",arrayOf(gameId.toString()))
            val events=snapshot.optJSONArray("events")?:JSONArray()
            var importedEvents=0
            for(index in 0 until events.length()){
                val event=events.getJSONObject(index)
                val teamId=if(event.optString("side")=="AWAY")awayId else homeId
                val number=event.optString("playerNumber").trim()
                val playerName=event.optString("playerName").trim()
                val playerId=if(number.isBlank()&&playerName.isBlank())null else findPlayer(teamId,playerName,number)?.id
                    ?:addPlayer(teamId,playerName,number).also{createdPlayers++}
                db.insertOrThrow("event",null,ContentValues().apply{
                    put("id",nextLocalId("event","events"))
                    put("game_id",gameId);put("team_id",teamId);if(playerId!=null)put("player_id",playerId)
                    put("type",event.optString("type"));put("value",event.optInt("value"))
                    put("period",event.optInt("period",1));put("game_clock_ms",event.optLong("gameClockMs"))
                    put("segment",0);put("segment_time_ms",0);put("final_video_time_ms",0)
                    put("reverted",if(event.optBoolean("reverted"))1 else 0)
                    put("created_at",System.currentTimeMillis())
                })
                importedEvents++
            }
            db.setTransactionSuccessful()
            return GameImport(gameId,importedEvents,createdTeams,createdPlayers)
        }finally{db.endTransaction()}
    }

    fun exportSyncSnapshot():JSONObject=JSONObject().apply{
        put("schemaVersion",1)
        put("updatedAt",System.currentTimeMillis())
        put("teams",queryJson("SELECT id,name,created_at FROM team ORDER BY id",arrayOf("id","name","created_at")))
        put("players",queryJson("SELECT id,team_id,name,number FROM player ORDER BY id",arrayOf("id","team_id","name","number")))
        put("games",queryJson("SELECT id,title,home_id,away_id,home_score,away_score,status,scheduled_at,video_quality,period_count,period_duration_ms,current_period,clock_remaining_ms,created_at FROM game ORDER BY id",arrayOf("id","title","home_id","away_id","home_score","away_score","status","scheduled_at","video_quality","period_count","period_duration_ms","current_period","clock_remaining_ms","created_at")))
        put("events",queryJson("SELECT id,game_id,team_id,player_id,type,value,period,game_clock_ms,segment,segment_time_ms,final_video_time_ms,reverted,created_at FROM event ORDER BY id",arrayOf("id","game_id","team_id","player_id","type","value","period","game_clock_ms","segment","segment_time_ms","final_video_time_ms","reverted","created_at")))
        put("segments",queryJson("SELECT id,game_id,sequence,uri,duration_ms,created_at FROM segment ORDER BY id",arrayOf("id","game_id","sequence","uri","duration_ms","created_at")))
        put("deletions",queryJson("SELECT entity,local_id,deleted_at,device_id FROM deletion ORDER BY deleted_at",arrayOf("entity","local_id","deleted_at","device_id")))
    }

    private fun queryJson(sql:String,columns:Array<String>):JSONArray=readableDatabase.rawQuery(sql,null).use{cursor->JSONArray().apply{while(cursor.moveToNext()){put(JSONObject().apply{columns.forEachIndexed{index,column->if(cursor.isNull(index))put(column,JSONObject.NULL)else when(cursor.getType(index)){android.database.Cursor.FIELD_TYPE_INTEGER->put(column,cursor.getLong(index));android.database.Cursor.FIELD_TYPE_FLOAT->put(column,cursor.getDouble(index));else->put(column,cursor.getString(index))}}})}}}

    fun mergeSyncSnapshot(snapshot:JSONObject){
        val db=writableDatabase
        db.beginTransaction()
        try{
            mergeRows(db,"team",snapshot.optJSONArray("teams"),arrayOf("id","name","created_at"))
            mergeRows(db,"player",snapshot.optJSONArray("players"),arrayOf("id","team_id","name","number"))
            mergeRows(db,"game",snapshot.optJSONArray("games"),arrayOf("id","title","home_id","away_id","home_score","away_score","status","scheduled_at","video_quality","period_count","period_duration_ms","current_period","clock_remaining_ms","created_at"))
            mergeRows(db,"segment",snapshot.optJSONArray("segments"),arrayOf("id","game_id","sequence","uri","duration_ms","created_at"))
            mergeRows(db,"event",snapshot.optJSONArray("events"),arrayOf("id","game_id","team_id","player_id","type","value","period","game_clock_ms","segment","segment_time_ms","final_video_time_ms","reverted","created_at"))
            // The cloud game row can lag behind its event rows. Reconcile after all dependent rows
            // are present so Download cannot reintroduce an old 0:0 score or opening clock.
            val mergedGameIds = (snapshot.optJSONArray("games") ?: JSONArray()).let { rows ->
                (0 until rows.length()).map { rows.getJSONObject(it).optLong("id") }
            }
            mergedGameIds.forEach { reconcileGameSummary(it) }
            mergeRows(db,"deletion",snapshot.optJSONArray("deletions"),arrayOf("entity","local_id","deleted_at","device_id"))
            applyDeletions(db)
            db.setTransactionSuccessful()
        }finally{db.endTransaction()}
    }

    /** Replays every tombstone this device knows about, so a game deleted elsewhere disappears here too. */
    private fun applyDeletions(db:SQLiteDatabase){
        DELETABLE_ENTITIES.forEach{(entity,table)->
            db.execSQL("DELETE FROM $table WHERE id IN (SELECT local_id FROM deletion WHERE entity=?)",arrayOf<Any>(entity))
        }
    }

    /** Tombstones this device still has to push, newest last. */
    fun pendingDeletions():JSONArray=queryJson("SELECT entity,local_id,deleted_at,device_id FROM deletion ORDER BY deleted_at",arrayOf("entity","local_id","deleted_at","device_id"))

    private fun mergeRows(db:SQLiteDatabase,table:String,rows:JSONArray?,columns:Array<String>){
        if(rows==null)return
        for(index in 0 until rows.length()){
            val row=rows.getJSONObject(index)
            val values=ContentValues()
            columns.forEach{column->if(row.has(column)&&!row.isNull(column)){val value=row.get(column);when(value){is Number->values.put(column,value.toLong());else->values.put(column,value.toString())}}}
            db.insertWithOnConflict(table,null,values,SQLiteDatabase.CONFLICT_REPLACE)
        }
    }
}
