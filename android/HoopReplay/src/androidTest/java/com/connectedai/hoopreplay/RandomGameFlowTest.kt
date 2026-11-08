package com.connectedai.hoopreplay

import android.Manifest
import android.content.ContentValues
import android.graphics.Bitmap
import android.provider.MediaStore
import android.util.Log
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.printToString
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import kotlin.random.Random
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RandomGameFlowTest {
    @get:Rule(order = 0)
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(
        Manifest.permission.CAMERA,
        Manifest.permission.RECORD_AUDIO
    )

    @get:Rule(order = 1)
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun randomGame_recordsPlaysAndCapturesStatistics() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val seed = System.currentTimeMillis()
        val random = Random(seed)
        Log.i(TAG, "Random test seed: $seed")

        val suffix = seed.toString().takeLast(6)
        val homeName = "Comets-$suffix"
        val awayName = "Falcons-$suffix"
        val db = HoopDb(context)
        val homeId = db.addTeam(homeName)
        val awayId = db.addTeam(awayName)
        val homePlayers = createRandomPlayers(db, homeId, "C", random)
        val awayPlayers = createRandomPlayers(db, awayId, "F", random)
        val gameId = db.addGame(
            title = "$homeName vs $awayName",
            home = homeId,
            away = awayId,
            scheduledAt = seed,
            videoQuality = "HD",
            periodCount = 4,
            periodDurationMs = 8 * 60_000L
        )

        // The home lists are queried once per shell composition, so data seeded after launch needs
        // a page round-trip: open a team page and come back, then return to the Games tab.
        compose.onAllNodesWithText("Teams")[0].performClick()
        // The team list is lazy, so filter it first: the card is composed only when visible.
        compose.onNodeWithText("Search teams").performTextInput(homeName)
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasText(homeName) and hasClickAction()).fetchSemanticsNodes().isNotEmpty()
        }
        clickLast(homeName)
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Back").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Back").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Games").fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodesWithText("Games")[0].performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("$homeName vs $awayName").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("$homeName vs $awayName").assertIsDisplayed()
        compose.onNodeWithText("$homeName vs $awayName").performClick()
        compose.onNodeWithText("Record").performClick()
        // Wait for the recorder screen (its Start button) before touching the team panels.
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Start").fetchSemanticsNodes().isNotEmpty() }

        selectStartingLineup(0, homePlayers)
        selectStartingLineup(0, awayPlayers)

        val plays = buildCoveredPlaySequence(random)
        plays.forEach { play ->
            val teamIndex = play.teamIndex
            val players = if (teamIndex == 0) homePlayers else awayPlayers
            when (play.kind) {
                PlayKind.TWO_POINTS -> recordMadeShot(teamIndex, 2, players.random(random))
                PlayKind.THREE_POINTS -> recordMadeShot(teamIndex, 3, players.random(random))
                PlayKind.MISSED_SHOT -> recordMiss(teamIndex, 2, players.random(random))
                PlayKind.FREE_THROW -> recordFreeThrows(teamIndex, listOf(true, random.nextBoolean()))
                PlayKind.REBOUND -> recordStat(teamIndex, "Rebound", players.random(random))
                PlayKind.ASSIST -> recordStat(teamIndex, "Assist", players.random(random))
                PlayKind.STEAL -> recordStat(teamIndex, "Steal", players.random(random))
                PlayKind.BLOCK -> recordStat(teamIndex, "Block", players.random(random))
                PlayKind.TURNOVER -> recordStat(teamIndex, "Turnover", players.random(random))
                PlayKind.FOUL -> recordStat(teamIndex, "Foul", players.random(random))
            }
        }

        assertCovered(db, gameId, homeId)
        assertCovered(db, gameId, awayId)

        compose.onNodeWithText("Stats").performClick()
        // The stats dialog has no title; the totals row proves the table rendered.
        waitForText("Team Total")
        saveScreenshot("HoopReplay_stats_home_${gameId}_$seed.png")
        compose.onAllNodesWithText("$awayName (A)")[1]
            .performSemanticsAction(SemanticsActions.OnClick) { action -> action.invoke() }
        compose.waitForIdle()
        saveScreenshot("HoopReplay_stats_away_${gameId}_$seed.png")
    }

    private fun createRandomPlayers(db: HoopDb, teamId: Long, prefix: String, random: Random): List<String> {
        (1..7).forEach { index ->
            val number = random.nextInt(0, 100).toString()
            val name = "$prefix-Player-$index-${random.nextInt(100, 999)}"
            db.addPlayer(teamId, name, number)
        }
        return db.players(teamId).map { "#${it.number} ${it.name}" }
    }

    private fun selectStartingLineup(teamIndex: Int, players: List<String>) {
        // Semantic clicks are immune to layout still settling right after the screen opens.
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText("Lineup 0/5", substring = true).fetchSemanticsNodes().size > teamIndex
        }
        compose.onAllNodesWithText("Lineup 0/5", substring = true)[teamIndex]
            .performSemanticsAction(SemanticsActions.OnClick) { it.invoke() }
        players.take(1).forEach { clickPlayer(it) }
        compose.onNodeWithText("Confirm").performClick()
    }

    private fun recordMadeShot(teamIndex: Int, points: Int, player: String) {
        compose.onAllNodesWithText("+$points")[teamIndex].performClick()
        clickPlayer(player)
        waitForText("No assist")
        semanticClick("No assist")
    }

    private fun recordMiss(teamIndex: Int, points: Int, player: String) {
        compose.onAllNodesWithText("Miss $points")[teamIndex].performClick()
        clickPlayer(player)
        waitForText("No rebound")
        semanticClick("No rebound")
    }

    private fun recordStat(teamIndex: Int, stat: String, player: String) {
        compose.onAllNodesWithText(stat)[teamIndex].performClick()
        clickPlayer(player)
        // A foul asks who was fouled as a second step; defer that pick to keep one event per play.
        if (stat == "Foul") {
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

    private fun clickPlayer(player: String) = clickLast(player.substringAfter(' '), substring = true)

    private fun semanticClick(text: String) = clickLast(text)

    private fun recordFreeThrows(teamIndex: Int, outcomes: List<Boolean>) {
        compose.onAllNodesWithText("Free Throw")[teamIndex].performClick()
        waitForText("Assign later")
        semanticClick("Assign later")
        // Pick the trip length, then mark each attempt in its own Made/Miss column; the dialog
        // saves itself once the last attempt is recorded.
        waitForText("${outcomes.size} FTs")
        semanticClick("${outcomes.size} FTs")
        outcomes.forEachIndexed { attempt, made ->
            val label = if (made) "Made +1" else "Miss"
            val columns = compose.onAllNodes(hasText(label) and hasClickAction())
            compose.waitUntil(8_000) { columns.fetchSemanticsNodes().size > attempt }
            columns[attempt].performSemanticsAction(SemanticsActions.OnClick) { it.invoke() }
            compose.waitForIdle()
        }
        // A missed last attempt hands off to the rebound dialog before anything is saved.
        if (!outcomes.last()) {
            waitForText("No rebound")
            semanticClick("No rebound")
            compose.waitForIdle()
        }
    }

    /**
     * Randomized depth-first search. A state is the set of team/stat pairs already
     * covered; a solution must exercise every visible box-score column for both teams.
     */
    private fun buildCoveredPlaySequence(random: Random): List<Play> {
        val requiredKinds = listOf(
            PlayKind.TWO_POINTS, PlayKind.FREE_THROW, PlayKind.REBOUND, PlayKind.ASSIST,
            PlayKind.STEAL, PlayKind.BLOCK, PlayKind.TURNOVER, PlayKind.FOUL
        )
        val required = (0..1).flatMap { team -> requiredKinds.map { Play(team, it) } }.toSet()

        fun dfs(covered: Set<Play>, path: List<Play>): List<Play>? {
            if (covered.containsAll(required)) return path
            val candidates = (required - covered).shuffled(random)
            for (next in candidates) {
                dfs(covered + next, path + next)?.let { return it }
            }
            return null
        }

        val coveringPath = checkNotNull(dfs(emptySet(), emptyList()))
        val extraKinds = PlayKind.entries
        val extras = List(6) { Play(random.nextInt(2), extraKinds.random(random)) }
        return (coveringPath + extras).shuffled(random)
    }

    private fun assertCovered(db: HoopDb, gameId: Long, teamId: Long) {
        val events = db.events(gameId).filter { it.teamId == teamId && !it.reverted }
        check(events.any { it.type.startsWith("PTS_") || it.type == "FT_MADE" }) { "Missing points for team $teamId" }
        listOf("REB", "AST", "STL", "BLK", "TOV", "FOUL").forEach { type ->
            check(events.any { it.type == type && it.playerId != null }) { "Missing $type for team $teamId" }
        }
    }

    private fun waitForText(text: String) {
        try {
            compose.waitUntil(5_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
        } catch (error: Throwable) {
            throw AssertionError("Timed out waiting for '$text'. UI tree:\n${compose.onAllNodes(isRoot(), useUnmergedTree = true).printToString(maxDepth = 10)}", error)
        }
    }

    private fun saveScreenshot(fileName: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val resolver = instrumentation.targetContext.contentResolver
        val uri = resolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/HoopReplayTests")
            }
        ) ?: error("Could not create screenshot media entry")
        resolver.openOutputStream(uri).use { output ->
            checkNotNull(output)
            check(instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, output))
        }
        Log.i(TAG, "Statistics screenshot: $uri")
    }

    companion object {
        private const val TAG = "HoopReplayTest"
    }

    private data class Play(val teamIndex: Int, val kind: PlayKind)
    private enum class PlayKind {
        TWO_POINTS, THREE_POINTS, MISSED_SHOT, FREE_THROW,
        REBOUND, ASSIST, STEAL, BLOCK, TURNOVER, FOUL
    }
}
