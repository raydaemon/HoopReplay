package com.connectedai.hoopreplay

import android.Manifest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ScoreAdjustAssignLaterTest {
    // Seeded in the constructor so the rows already exist when the activity first builds its lists.
    private val suffix = System.currentTimeMillis().toString().takeLast(6)
    private val homeName = "AdjH-$suffix"
    private val awayName = "AdjA-$suffix"
    private val db = HoopDb(InstrumentationRegistry.getInstrumentation().targetContext)
    private val homeId = db.addTeam(homeName)
    private val awayId = db.addTeam(awayName)
    private val gameId = run {
        db.addPlayer(homeId, "Adj-Player-One", "4")
        db.addPlayer(awayId, "Adj-Player-Two", "5")
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

    private fun waitForText(text: String) =
        compose.waitUntil(10_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }

    private fun semanticClick(text: String) = compose.onNodeWithText(text)
        .performSemanticsAction(SemanticsActions.OnClick) { it.invoke() }

    private fun openScoreScreen() {
        waitForText("$homeName vs $awayName")
        // A touch on the card's centre can land on a team-name link inside it, so invoke the
        // card's own click action instead of injecting a tap.
        semanticClick("$homeName vs $awayName")
        waitForText("Score")
        compose.onNodeWithText("Score").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("+1").fetchSemanticsNodes().size == 2 }
    }

    @Test
    fun adjustButtons_moveScoreAndAssignLaterDefersPlayer() {
        openScoreScreen()

        // Home panel is composed first, so index 0 addresses the home team.
        compose.onAllNodesWithText("+1")[0].performClick()
        compose.waitForIdle()
        compose.onAllNodesWithText("+1")[0].performClick()
        compose.waitForIdle()
        assertEquals(2, game().homeScore)
        compose.onAllNodesWithText("-1")[0].performClick()
        compose.waitForIdle()
        assertEquals(1, game().homeScore)

        // The away score is 0, so -1 must not push it negative.
        compose.onAllNodesWithText("-1")[1].performClick()
        compose.waitForIdle()
        assertEquals(0, game().awayScore)
        compose.onAllNodesWithText("+1")[1].performClick()
        compose.waitForIdle()
        assertEquals(1, game().awayScore)

        val adjustments = db.events(gameId).filterNot { it.reverted }.filter { it.type == "ADJ" }
        // Home +1, +1, -1 and away +1; the away -1 at zero was correctly refused.
        assertEquals(4, adjustments.size)
        assertTrue(adjustments.all { it.playerId == null })

        // Assign later on a made shot still asks for the assist, then scores without a player.
        compose.onAllNodesWithText("+2")[0].performClick()
        waitForText("Assign later")
        compose.onNodeWithText("Assign later").performClick()
        waitForText("No assist")
        semanticClick("No assist")
        compose.waitForIdle()
        assertEquals(3, game().homeScore)
        val deferredShot = db.events(gameId).filterNot { it.reverted }.first { it.type == "PTS_2" }
        assertEquals(null, deferredShot.playerId)

        // Assign later works for both foul questions and records an unassigned foul.
        compose.onAllNodesWithText("Foul")[0].performClick()
        waitForText("Who committed the foul?")
        compose.onNodeWithText("Assign later").performClick()
        waitForText("Who was fouled?")
        compose.onNodeWithText("Assign later").performClick()
        compose.waitForIdle()
        val foul = db.events(gameId).filterNot { it.reverted }.first { it.type == "FOUL" }
        assertEquals(null, foul.playerId)

        // The clock editor is wheels-only: no titles, no time preview, no Next Period button —
        // just the pickers with Cancel and Save.
        compose.onNodeWithText("Period/Time").performClick()
        waitForText("Save")
        assertTrue(compose.onAllNodesWithText("Next Period").fetchSemanticsNodes().isEmpty())
        assertTrue(compose.onAllNodesWithText("Adjust period and clock").fetchSemanticsNodes().isEmpty())
        compose.onNodeWithText("Save").performClick()
        compose.waitForIdle()
        assertEquals(1, game().currentPeriod)
        compose.onNodeWithText("Period 1/4  08:00", substring = true).assertIsDisplayed()
    }

    @Test
    fun chooseNumber_picksOrCreatesThePlayerByJersey() {
        openScoreScreen()

        // "Choose number" is the last cell of the player grid and swaps to the 0-99 pad.
        compose.onAllNodesWithText("+2")[0].performClick()
        waitForText("Choose number")
        semanticClick("Choose number")
        waitForText("99")
        // 37 is not on the roster: picking it creates the player and returns to the list,
        // where the new number now has its own button; tapping that button records the play.
        semanticClick("37")
        waitForText("Assign later")
        semanticClick("37")
        waitForText("No assist")
        semanticClick("No assist")
        compose.waitForIdle()
        assertEquals(2, game().homeScore)
        val shot = db.events(gameId).filterNot { it.reverted }.first { it.type == "PTS_2" }
        val created = db.players(homeId).first { it.id == shot.playerId }
        assertEquals("37", created.number)

        // An existing player's button records the play directly, with no duplicate created.
        compose.onAllNodesWithText("Rebound")[0].performClick()
        waitForText("Assign later")
        semanticClick("Adj-Player-One")
        compose.waitForIdle()
        val rebound = db.events(gameId).filterNot { it.reverted }.first { it.type == "REB" }
        val existing = db.players(homeId).first { it.id == rebound.playerId }
        assertEquals("Adj-Player-One", existing.name)
        // No duplicate #4 was created.
        assertEquals(1, db.players(homeId).count { it.number == "4" })

        // Tapping a highlighted number unselects it: the player is removed from the roster and
        // from the list; a player with recorded stats stays.
        compose.onAllNodesWithText("+2")[0].performClick()
        waitForText("Choose number")
        semanticClick("Choose number")
        waitForText("99")
        semanticClick("88")
        waitForText("Assign later")
        assertTrue(db.players(homeId).any { it.number == "88" })
        semanticClick("Choose number")
        waitForText("99")
        semanticClick("88")
        compose.waitForIdle()
        assertTrue(db.players(homeId).none { it.number == "88" })
        // #37 already scored, so unselecting must keep them.
        semanticClick("37")
        compose.waitForIdle()
        assertTrue(db.players(homeId).any { it.number == "37" })
        Espresso.pressBack()
        waitForText("Assign later")
        assertTrue(compose.onAllNodesWithText("88").fetchSemanticsNodes().isEmpty())
        compose.onNodeWithText("Cancel").performClick()
    }
}
