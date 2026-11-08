package com.connectedai.hoopreplay

import android.Manifest
import android.content.ContentValues
import android.graphics.Bitmap
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NbaFinalsFirstQuarterTest {
    private val nameSuffix = System.currentTimeMillis()
    private val spursName = "San Antonio Spurs Q1-$nameSuffix"
    private val knicksName = "New York Knicks Q1-$nameSuffix"

    @get:Rule(order = 0)
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(
        Manifest.permission.CAMERA,
        Manifest.permission.RECORD_AUDIO
    )

    @get:Rule(order = 1)
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun importsOfficial2026FinalsGame1FirstQuarter() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val db = HoopDb(context)
        val spursId = db.addTeam(spursName)
        val knicksId = db.addTeam(knicksName)
        importTeam(db, spursId, SPURS)
        importTeam(db, knicksId, KNICKS)
        val gameId = db.addGame(
            title = "2026 NBA Finals G1 - First Quarter",
            home = spursId,
            away = knicksId,
            scheduledAt = 1_780_537_800_000L,
            videoQuality = "FHD",
            periodCount = 4,
            periodDurationMs = 12 * 60_000L
        )
        // The home lists are queried once per shell composition, so data seeded after launch needs
        // a page round-trip: open a team page and come back, then return to the Games tab.
        compose.onAllNodesWithText("Teams")[0].performClick()
        // The team list is lazy, so filter it first: the card is composed only when visible.
        compose.onNodeWithText("Search teams").performTextInput(spursName)
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasText(spursName) and hasClickAction()).fetchSemanticsNodes().isNotEmpty()
        }
        clickLast(spursName)
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Back").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Back").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Games").fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodesWithText("Games")[0].performClick()
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText("2026 NBA Finals G1 - First Quarter").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onAllNodesWithText("2026 NBA Finals G1 - First Quarter")[0].performClick()
        compose.onNodeWithText("Record").performClick()
        replayOfficialTimeline(db, gameId)
        assertOfficialStats(db, gameId, spursId, SPURS)
        assertOfficialStats(db, gameId, knicksId, KNICKS)
        val completedGame = db.games().first { it.id == gameId }
        check(completedGame.homeScore == 27) { "Expected Spurs 27, got ${completedGame.homeScore}" }
        check(completedGame.awayScore == 19) { "Expected Knicks 19, got ${completedGame.awayScore}" }

        compose.onNodeWithText("Stats").performClick()
        // The stats dialog has no title; the totals row proves the table rendered.
        waitForText("Team Total")
        compose.waitForIdle()
        saveScreenshot("NBA_Finals_2026_G1_Q1_Spurs.png")

        compose.onAllNodesWithText("$knicksName (A)")[1]
            .performSemanticsAction(SemanticsActions.OnClick) { it.invoke() }
        compose.waitForIdle()
        saveScreenshot("NBA_Finals_2026_G1_Q1_Knicks.png")

        // The Export PDF action lives on the game-detail screen now; the export routine itself is
        // what this test verifies, so call it directly like PdfExportTest does.
        val pdfName = exportStatsPdf(context, db, db.games().first { it.id == gameId })
        val pdfFile = java.io.File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "HoopReplay/$pdfName"
        )
        compose.waitUntil(10_000) { pdfFile.length() > 500L }
        check(pdfFile.length() > 500L) { "Statistics PDF was not generated: $pdfFile" }
        Log.i(TAG, "NBA_PDF_FILE=${pdfFile.absolutePath}")
    }

    private fun importTeam(db: HoopDb, teamId: Long, stats: List<PlayerStats>) {
        stats.forEach { db.addPlayer(teamId, it.name, it.number) }
    }

    private fun replayOfficialTimeline(db: HoopDb, gameId: Long) {
        var expectedSpurs = 0
        var expectedKnicks = 0
        OFFICIAL_Q1.forEachIndexed { index, play ->
            val eventCountBefore = db.events(gameId).size
            Log.i(TAG, "NBA_STEP ${index + 1}/${OFFICIAL_Q1.size} Q1 ${play.clock} ${play.description}")
            when (play) {
                is MadeShot -> recordMadeShot(play.team.index, play.points, play.player, play.assist)
                is MissedShot -> recordMissedShot(play.team.index, play.points, play.player, play.rebound)
                is FreeThrows -> recordFreeThrows(play.team.index, play.player, play.made)
                is Stat -> recordStat(play.team.index, play.label, play.player)
            }

            val clockMs = parseClock(play.clock)
            val newEvents = db.events(gameId).drop(eventCountBefore)
            check(newEvents.isNotEmpty()) { "No event saved for Q1 ${play.clock}: ${play.description}" }
            val ids = newEvents.joinToString(",") { it.id.toString() }
            db.writableDatabase.execSQL(
                "UPDATE event SET game_clock_ms=? WHERE id IN ($ids)",
                arrayOf(clockMs)
            )

            when (play) {
                is MadeShot -> if (play.team == TeamSide.SPURS) expectedSpurs += play.points else expectedKnicks += play.points
                is FreeThrows -> if (play.team == TeamSide.SPURS) expectedSpurs += play.made.count { it } else expectedKnicks += play.made.count { it }
                else -> Unit
            }
            val game = db.games().first { it.id == gameId }
            check(game.homeScore == expectedSpurs && game.awayScore == expectedKnicks) {
                "Q1 ${play.clock} score mismatch after ${play.description}: expected SAS $expectedSpurs-NYK $expectedKnicks, got SAS ${game.homeScore}-NYK ${game.awayScore}"
            }
        }
    }

    private fun recordMadeShot(teamIndex: Int, points: Int, playerName: String, assist: String?) {
        waitForText("+$points")
        compose.onAllNodesWithText("+$points")[teamIndex].performClick()
        clickPlayer(playerName)
        waitForText("Who made the assist?")
        if (assist == null) semanticClick("No assist") else clickPlayer(assist)
    }

    private fun recordFreeThrows(teamIndex: Int, playerName: String, made: List<Boolean>) {
        waitForText("Free Throw")
        compose.onAllNodesWithText("Free Throw")[teamIndex].performClick()
        clickPlayer(playerName)
        // Pick the trip length, then mark each attempt in its own Made/Miss column; the dialog
        // saves itself once the last attempt is recorded.
        waitForText("Number of free throws")
        compose.onNodeWithText(if (made.size == 1) "1 FT" else "${made.size} FTs").performClick()
        made.forEachIndexed { attempt, isMade ->
            val label = if (isMade) "Made +1" else "Miss"
            val columns = compose.onAllNodes(hasText(label) and hasClickAction())
            compose.waitUntil(8_000) { columns.fetchSemanticsNodes().size > attempt }
            columns[attempt].performSemanticsAction(SemanticsActions.OnClick) { it.invoke() }
            compose.waitForIdle()
        }
        // A missed last attempt leaves the ball live, so the rebound dialog follows; the official
        // timeline records that rebound as its own play, so decline it here.
        if (!made.last()) {
            waitForText("No rebound")
            semanticClick("No rebound")
            compose.waitForIdle()
        }
    }

    private fun recordMissedShot(teamIndex: Int, points: Int, playerName: String, rebound: String?) {
        waitForText("Miss $points")
        compose.onAllNodesWithText("Miss $points")[teamIndex].performClick()
        clickPlayer(playerName)
        // The rebound dialog shows one team per tab, starting on the shooting team; a defensive
        // rebounder only appears after switching to the other team's tab.
        waitForText("No rebound")
        if (rebound == null) {
            semanticClick("No rebound")
        } else {
            if (compose.onAllNodesWithText(rebound, substring = true).fetchSemanticsNodes().isEmpty()) {
                val otherTeam = if (teamIndex == TeamSide.SPURS.index) knicksName else spursName
                clickLast(otherTeam, substring = true)
                compose.waitUntil(8_000) {
                    compose.onAllNodesWithText(rebound, substring = true).fetchSemanticsNodes().isNotEmpty()
                }
            }
            clickPlayer(rebound)
        }
    }

    private fun parseClock(value: String): Long {
        val (minutes, seconds) = value.split(':').map(String::toLong)
        return (minutes * 60 + seconds) * 1_000
    }

    private fun recordStat(teamIndex: Int, label: String, playerName: String) {
        waitForText(label)
        compose.onAllNodesWithText(label)[teamIndex].performClick()
        clickPlayer(playerName)
        // A foul asks a second question; the fouled player is not part of the official play line.
        if (label == "Foul") {
            waitForText("Who was fouled?")
            semanticClick("Assign later")
        }
    }

    // Dialogs can briefly overlap while one closes and the next opens, so the same label may
    // exist twice; the newest window sits last in the tree.
    private fun clickLast(text: String, substring: Boolean = false) {
        val nodes = compose.onAllNodes(hasText(text, substring = substring) and hasClickAction())
        compose.waitUntil(8_000) { nodes.fetchSemanticsNodes().isNotEmpty() }
        val count = nodes.fetchSemanticsNodes().size
        nodes[count - 1].performSemanticsAction(SemanticsActions.OnClick) { it.invoke() }
    }

    private fun clickPlayer(playerName: String) = clickLast(playerName, substring = true)

    private fun semanticClick(text: String) = clickLast(text)

    private fun waitForText(text: String) {
        compose.waitUntil(8_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun assertOfficialStats(db: HoopDb, gameId: Long, teamId: Long, expected: List<PlayerStats>) {
        val players = db.players(teamId).associateBy { it.number }
        val events = db.events(gameId).filter { it.teamId == teamId && !it.reverted }
        expected.forEach { stat ->
            val playerId = checkNotNull(players[stat.number]).id
            val playerEvents = events.filter { it.playerId == playerId }
            fun total(type: String) = playerEvents.filter { it.type == type }.sumOf { it.value }
            val points = playerEvents.filter { it.type.startsWith("PTS_") || it.type == "FT_MADE" }.sumOf { it.value }
            check(points == stat.points) { "${stat.name}: expected ${stat.points} PTS, got $points" }
            check(total("REB") == stat.rebounds) { "${stat.name}: REB mismatch" }
            check(total("AST") == stat.assists) { "${stat.name}: AST mismatch" }
            check(total("STL") == stat.steals) { "${stat.name}: STL mismatch" }
            check(total("BLK") == stat.blocks) { "${stat.name}: BLK mismatch" }
            check(total("TOV") == stat.turnovers) { "${stat.name}: TOV mismatch" }
            check(total("FOUL") == stat.fouls) { "${stat.name}: PF mismatch" }
        }
    }

    private fun saveScreenshot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val uri = checkNotNull(instrumentation.targetContext.contentResolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/HoopReplayTests")
            }
        ))
        instrumentation.targetContext.contentResolver.openOutputStream(uri).use { output ->
            check(instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, checkNotNull(output)))
        }
        Log.i(TAG, "$name: $uri")
    }

    private data class PlayerStats(
        val number: String,
        val name: String,
        val points: Int,
        val fieldGoals: List<Int>,
        val freeThrows: Int,
        val rebounds: Int,
        val assists: Int,
        val steals: Int,
        val blocks: Int,
        val turnovers: Int,
        val fouls: Int
    )

    private enum class TeamSide(val index: Int) { SPURS(0), KNICKS(1) }

    private sealed interface Play {
        val clock: String
        val team: TeamSide
        val description: String
    }

    private data class MadeShot(override val clock: String, override val team: TeamSide, val player: String, val points: Int, val assist: String? = null) : Play {
        override val description = "$player makes $points${assist?.let { " ($it assists)" }.orEmpty()}"
    }

    private data class MissedShot(override val clock: String, override val team: TeamSide, val player: String, val points: Int, val rebound: String? = null) : Play {
        override val description = "$player misses $points${rebound?.let { "; $it rebounds" }.orEmpty()}"
    }

    private data class FreeThrows(override val clock: String, override val team: TeamSide, val player: String, val made: List<Boolean>) : Play {
        override val description = "$player free throws ${made.joinToString { if (it) "made" else "missed" }}"
    }

    private data class Stat(override val clock: String, override val team: TeamSide, val label: String, val player: String) : Play {
        override val description = "$player: $label"
    }

    companion object {
        private const val TAG = "HoopReplayNBA"

        // NBA official game page (Box Score / Play-By-Play):
        // https://www.nba.com/game/nyk-vs-sas-0042500401/play-by-play
        // NBA Official Scorer's Report (the period totals confirm Spurs 27–19 Knicks in Q1):
        // https://statsdmz.nba.com/pdfs/20260603/20260603_NYKSAS.pdf
        // NBA official scorer's book (Q1 Play-by-Play, pages 9–10):
        // https://statsdmz.nba.com/pdfs/20260603/20260603_NYKSAS_book.pdf
        private val KNICKS = listOf(
            PlayerStats("3", "Josh Hart", 2,listOf(2),0,5,2,0,1,0,2),
            PlayerStats("8", "OG Anunoby", 5,listOf(3,2),0,0,0,0,0,0,0),
            PlayerStats("32", "Karl-Anthony Towns", 4,listOf(2,2),0,2,2,0,0,1,0),
            PlayerStats("25", "Mikal Bridges", 2,listOf(2),0,2,1,2,0,0,1),
            PlayerStats("11", "Jalen Brunson", 3,listOf(3),0,1,1,0,0,2,0),
            PlayerStats("44", "Landry Shamet", 3,listOf(3),0,0,0,0,0,0,2),
            PlayerStats("2", "Miles McBride", 0,emptyList(),0,1,0,0,0,0,0),
            PlayerStats("23", "Mitchell Robinson", 0,emptyList(),0,1,0,0,0,0,0),
            PlayerStats("5", "Jose Alvarado", 0,emptyList(),0,1,0,0,0,0,0)
        )

        private val SPURS = listOf(
            PlayerStats("24", "Devin Vassell", 2,listOf(2),0,2,0,0,0,0,0),
            PlayerStats("30", "Julian Champagnie", 6,listOf(3,3),0,5,0,0,1,0,1),
            PlayerStats("1", "Victor Wembanyama", 5,listOf(2,3),0,1,0,1,1,1,0),
            PlayerStats("5", "Stephon Castle", 4,listOf(2),2,4,1,0,0,1,0),
            PlayerStats("4", "De'Aaron Fox", 0,emptyList(),0,1,3,0,0,0,0),
            PlayerStats("2", "Dylan Harper", 10,listOf(2,2,3),3,2,0,1,0,0,1),
            PlayerStats("3", "Keldon Johnson", 0,emptyList(),0,0,0,0,0,0,2),
            PlayerStats("7", "Luke Kornet", 0,emptyList(),0,1,0,1,0,0,0),
            PlayerStats("40", "Harrison Barnes", 0,emptyList(),0,0,1,0,0,0,0)
        )

        private val OFFICIAL_Q1: List<Play> = listOf(
            MadeShot("11:45", TeamSide.KNICKS, "Jalen Brunson", 3, "Karl-Anthony Towns"),
            MadeShot("11:22", TeamSide.SPURS, "Victor Wembanyama", 2),
            MissedShot("10:57", TeamSide.KNICKS, "Jalen Brunson", 2, "Josh Hart"),
            MadeShot("10:53", TeamSide.KNICKS, "OG Anunoby", 3, "Josh Hart"),
            MissedShot("10:31", TeamSide.SPURS, "Victor Wembanyama", 2, "Julian Champagnie"),
            MissedShot("10:29", TeamSide.SPURS, "Devin Vassell", 3, "Stephon Castle"),
            MissedShot("10:26", TeamSide.SPURS, "Stephon Castle", 2, "Jalen Brunson"),
            MissedShot("10:18", TeamSide.KNICKS, "Karl-Anthony Towns", 3, "Julian Champagnie"),
            Stat("10:06", TeamSide.SPURS, "Turnover", "Victor Wembanyama"),
            Stat("10:06", TeamSide.KNICKS, "Steal", "Mikal Bridges"),
            MadeShot("10:01", TeamSide.KNICKS, "OG Anunoby", 2, "Mikal Bridges"),
            MissedShot("09:47", TeamSide.SPURS, "Stephon Castle", 2, "Stephon Castle"),
            Stat("09:47", TeamSide.KNICKS, "Block", "Josh Hart"),
            MissedShot("09:36", TeamSide.SPURS, "Victor Wembanyama", 2, "Josh Hart"),
            MissedShot("09:29", TeamSide.KNICKS, "Mikal Bridges", 2, "Julian Champagnie"),
            MissedShot("09:20", TeamSide.SPURS, "De'Aaron Fox", 3, "Devin Vassell"),
            MadeShot("09:19", TeamSide.SPURS, "Devin Vassell", 2),
            MadeShot("08:56", TeamSide.KNICKS, "Josh Hart", 2, "Karl-Anthony Towns"),
            MissedShot("08:36", TeamSide.SPURS, "De'Aaron Fox", 3, "Josh Hart"),
            MissedShot("08:29", TeamSide.KNICKS, "Josh Hart", 2, "Stephon Castle"),
            Stat("08:29", TeamSide.SPURS, "Block", "Victor Wembanyama"),
            MadeShot("08:21", TeamSide.SPURS, "Victor Wembanyama", 3, "Stephon Castle"),
            MissedShot("07:52", TeamSide.KNICKS, "Jalen Brunson", 3),
            Stat("07:52", TeamSide.SPURS, "Block", "Julian Champagnie"),
            MissedShot("07:43", TeamSide.SPURS, "De'Aaron Fox", 3, "Josh Hart"),
            MadeShot("07:28", TeamSide.KNICKS, "Karl-Anthony Towns", 2),
            Stat("07:08", TeamSide.SPURS, "Turnover", "Stephon Castle"),
            Stat("07:08", TeamSide.KNICKS, "Steal", "Mikal Bridges"),
            MadeShot("06:59", TeamSide.KNICKS, "Karl-Anthony Towns", 2, "Josh Hart"),
            MissedShot("06:38", TeamSide.SPURS, "Stephon Castle", 3),
            Stat("06:37", TeamSide.SPURS, "Foul", "Keldon Johnson"),
            MissedShot("06:20", TeamSide.KNICKS, "Karl-Anthony Towns", 2, "Devin Vassell"),
            Stat("06:15", TeamSide.KNICKS, "Foul", "Josh Hart"),
            MadeShot("06:07", TeamSide.SPURS, "Stephon Castle", 2),
            MissedShot("05:55", TeamSide.KNICKS, "Josh Hart", 3, "Victor Wembanyama"),
            MissedShot("05:47", TeamSide.SPURS, "Keldon Johnson", 2, "Josh Hart"),
            Stat("05:33", TeamSide.KNICKS, "Turnover", "Karl-Anthony Towns"),
            Stat("05:33", TeamSide.SPURS, "Steal", "Victor Wembanyama"),
            Stat("05:27", TeamSide.KNICKS, "Foul", "Josh Hart"),
            FreeThrows("05:27", TeamSide.SPURS, "Stephon Castle", listOf(true, true)),
            MissedShot("05:08", TeamSide.KNICKS, "Landry Shamet", 3, "Karl-Anthony Towns"),
            MissedShot("05:04", TeamSide.KNICKS, "Karl-Anthony Towns", 2, "Stephon Castle"),
            MissedShot("04:54", TeamSide.SPURS, "Keldon Johnson", 3, "Mikal Bridges"),
            MissedShot("04:44", TeamSide.KNICKS, "Jalen Brunson", 2, "Dylan Harper"),
            MissedShot("04:36", TeamSide.SPURS, "Devin Vassell", 3),
            Stat("04:33", TeamSide.SPURS, "Foul", "Keldon Johnson"),
            Stat("04:15", TeamSide.KNICKS, "Turnover", "Jalen Brunson"),
            Stat("04:15", TeamSide.SPURS, "Steal", "Dylan Harper"),
            Stat("04:13", TeamSide.KNICKS, "Foul", "Mikal Bridges"),
            FreeThrows("04:13", TeamSide.SPURS, "Dylan Harper", listOf(true, true)),
            Stat("04:01", TeamSide.KNICKS, "Turnover", "Jalen Brunson"),
            Stat("04:01", TeamSide.SPURS, "Steal", "Luke Kornet"),
            MadeShot("03:58", TeamSide.SPURS, "Dylan Harper", 2),
            Stat("03:58", TeamSide.KNICKS, "Foul", "Landry Shamet"),
            FreeThrows("03:58", TeamSide.SPURS, "Dylan Harper", listOf(true)),
            MissedShot("03:36", TeamSide.KNICKS, "Jalen Brunson", 3, "Luke Kornet"),
            MadeShot("03:25", TeamSide.SPURS, "Dylan Harper", 3, "De'Aaron Fox"),
            MadeShot("03:12", TeamSide.KNICKS, "Landry Shamet", 3, "Jalen Brunson"),
            MadeShot("03:01", TeamSide.SPURS, "Julian Champagnie", 3, "De'Aaron Fox"),
            MissedShot("02:47", TeamSide.KNICKS, "Jalen Brunson", 2, "De'Aaron Fox"),
            MissedShot("02:43", TeamSide.SPURS, "Julian Champagnie", 3, "Mitchell Robinson"),
            Stat("02:33", TeamSide.SPURS, "Foul", "Dylan Harper"),
            MissedShot("02:19", TeamSide.KNICKS, "Jalen Brunson", 2, "Julian Champagnie"),
            MadeShot("02:03", TeamSide.SPURS, "Julian Champagnie", 3, "De'Aaron Fox"),
            Stat("02:03", TeamSide.KNICKS, "Foul", "Landry Shamet"),
            FreeThrows("02:03", TeamSide.SPURS, "Harrison Barnes", listOf(false)),
            Stat("01:59", TeamSide.KNICKS, "Rebound", "Miles McBride"),
            MissedShot("01:41", TeamSide.KNICKS, "Miles McBride", 3, "Dylan Harper"),
            MadeShot("01:28", TeamSide.SPURS, "Dylan Harper", 2, "Harrison Barnes"),
            MissedShot("01:16", TeamSide.KNICKS, "Miles McBride", 3, "Mikal Bridges"),
            MadeShot("01:15", TeamSide.KNICKS, "Mikal Bridges", 2),
            MissedShot("00:58", TeamSide.SPURS, "Victor Wembanyama", 2, "Jose Alvarado"),
            Stat("00:40", TeamSide.SPURS, "Foul", "Julian Champagnie"),
            MissedShot("00:27", TeamSide.KNICKS, "Jose Alvarado", 3, "Julian Champagnie"),
            MissedShot("00:02", TeamSide.SPURS, "Stephon Castle", 2, "Karl-Anthony Towns")
        )
    }
}
