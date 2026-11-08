package com.connectedai.hoopreplay

import android.Manifest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Covers the stat-button fixes: cancelling a follow-up question keeps the play already confirmed,
 * Undo re-derives the on-court lineup, and a foul also records the fouled player.
 */
@RunWith(AndroidJUnit4::class)
class StatButtonFixesTest {
    private val suffix = System.currentTimeMillis().toString().takeLast(6)
    private val homeName = "FixH-$suffix"
    private val awayName = "FixA-$suffix"
    private val db = HoopDb(InstrumentationRegistry.getInstrumentation().targetContext)
    private val homeId = db.addTeam(homeName)
    private val awayId = db.addTeam(awayName)
    private val gameId = run {
        db.addPlayer(homeId, "Fix-Player-One", "4")
        db.addPlayer(awayId, "Fix-Player-Two", "5")
        db.addGame(
            title = "$homeName vs $awayName",
            home = homeId,
            away = awayId,
            scheduledAt = System.currentTimeMillis(),
            videoQuality = "HD",
            periodCount = 4,
            periodDurationMs = 8 * 60_000L
        )
    }

    @get:Rule(order = 0)
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(
        Manifest.permission.CAMERA,
        Manifest.permission.RECORD_AUDIO
    )

    @get:Rule(order = 1)
    val compose = createAndroidComposeRule<MainActivity>()

    private fun game() = db.games().first { it.id == gameId }
    private fun active() = db.events(gameId).filterNot { it.reverted }
    private fun count(text: String) = compose.onAllNodesWithText(text).fetchSemanticsNodes().size

    private fun waitForText(text: String) =
        compose.waitUntil(10_000) { count(text) > 0 }

    private fun semanticClick(text: String) = compose.onNodeWithText(text)
        .performSemanticsAction(SemanticsActions.OnClick) { it.invoke() }

    private fun openScoreScreen() {
        // The app lands on the Home tab; the game list lives under Games, newest first.
        waitForText("Games")
        compose.onNodeWithText("Games").performClick()
        waitForText("$homeName vs $awayName")
        semanticClick("$homeName vs $awayName")
        waitForText("Score")
        compose.onNodeWithText("Score").performClick()
        compose.waitUntil(10_000) { count("+1") == 2 }
    }

    @Test
    fun cancelKeepsConfirmedPlay_undoRefreshesLineup_foulRecordsFouledPlayer() {
        openScoreScreen()
        assertEquals(2, count("⚠ Lineup 0/5"))

        // A stat on a fresh player never writes a STARTER: only the rebound itself is recorded,
        // and the panel shows the player on the floor until the log is re-derived.
        compose.onAllNodesWithText("Rebound")[0].performClick()
        waitForText("Who recorded this stat?")
        semanticClick("Fix-Player-One")
        compose.waitUntil(10_000) { count("⚠ Lineup 1/5") == 1 }
        assertEquals(listOf("REB"), active().map { it.type })
        // Undo the rebound: with no lineup event left, the panel count follows the event log.
        compose.onNodeWithText("Undo").performClick()
        compose.waitUntil(10_000) { count("⚠ Lineup 0/5") == 2 }
        assertTrue(active().isEmpty())

        // Cancel on the assist question keeps the made shot.
        compose.onAllNodesWithText("+2")[0].performClick()
        waitForText("Who scored?")
        semanticClick("Fix-Player-One")
        waitForText("Who made the assist?")
        compose.onNodeWithText("Cancel").performClick()
        compose.waitUntil(10_000) { game().homeScore == 2 }
        assertEquals(1, active().count { it.type == "PTS_2" })
        assertEquals(0, active().count { it.type == "AST" })

        // Cancel on the rebound question keeps the missed shot.
        compose.onAllNodesWithText("Miss 2")[0].performClick()
        waitForText("Who took this shot?")
        semanticClick("Fix-Player-One")
        waitForText("No rebound")
        compose.onNodeWithText("Cancel").performClick()
        compose.waitUntil(10_000) { active().any { it.type == "MISS_2" } }
        assertEquals(0, active().count { it.type == "REB" })

        // Cancel on the rebound question after a missed last free throw keeps the free throws.
        compose.onAllNodesWithText("Free Throw")[0].performClick()
        waitForText("Select shooter")
        semanticClick("Fix-Player-One")
        waitForText("Made +1")
        compose.onAllNodesWithText("Made +1")[0].performClick()
        compose.waitForIdle()
        compose.onAllNodesWithText("Miss")[1].performClick()
        waitForText("No rebound")
        compose.onNodeWithText("Cancel").performClick()
        compose.waitUntil(10_000) { game().homeScore == 3 }
        assertEquals(listOf("FT_MADE", "FT_MISS"), active().filter { it.type.startsWith("FT_") }.map { it.type })
        assertEquals(0, active().count { it.type == "REB" })

        // A foul records the fouled player on the opposing team.
        compose.onAllNodesWithText("Foul")[0].performClick()
        waitForText("Who committed the foul?")
        semanticClick("Fix-Player-One")
        waitForText("Who was fouled?")
        semanticClick("Fix-Player-Two")
        compose.waitUntil(10_000) { active().any { it.type == "FOULED" } }
        val foul = active().first { it.type == "FOUL" }
        val fouled = active().first { it.type == "FOULED" }
        assertEquals(homeId, foul.teamId)
        assertEquals(db.players(homeId).first { it.number == "4" }.id, foul.playerId)
        assertEquals(awayId, fouled.teamId)
        assertEquals(db.players(awayId).first { it.number == "5" }.id, fouled.playerId)
        // The fouled player was on the floor, so the away panel now shows 1/5 as well.
        compose.waitUntil(10_000) { count("⚠ Lineup 1/5") == 2 }
        waitForText("Foul drawn")
        assertEquals(3, game().homeScore)
    }
}
