package com.connectedai.hoopreplay

import android.Manifest
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * End-to-end coverage for docs/record_button_workflow_v3.md: two button positions, the
 * IDLE/RECORDING/PAUSED states, Pause/Resume on one file, and Stop finalizing automatically
 * with one Plays entry per finished file.
 */
@RunWith(AndroidJUnit4::class)
class RecordButtonWorkflowTest {
    private val suffix = System.currentTimeMillis().toString().takeLast(6)
    private val homeName = "RwH-$suffix"
    private val awayName = "RwA-$suffix"
    private val db = HoopDb(InstrumentationRegistry.getInstrumentation().targetContext)
    private val homeId = db.addTeam(homeName)
    private val awayId = db.addTeam(awayName)
    private val gameId = db.addGame(
        title = "$homeName vs $awayName",
        home = homeId,
        away = awayId,
        scheduledAt = System.currentTimeMillis(),
        videoQuality = "SD",
        periodCount = 4,
        periodDurationMs = 8 * 60_000L
    )

    @get:Rule(order = 0)
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(
        Manifest.permission.CAMERA,
        Manifest.permission.RECORD_AUDIO
    )

    @get:Rule(order = 1)
    val compose = createAndroidComposeRule<MainActivity>()

    @Before
    fun grantDndAccess() {
        // Recording is gated on notification-policy access; grant it the way a user would in
        // settings. Reading the stream to the end blocks until the command has actually run.
        val pfd = InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand("cmd notification allow_dnd com.connectedai.hoopreplay")
        android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes() }
    }

    private fun game() = db.games().first { it.id == gameId }

    private fun videoPlays() = db.events(gameId).filterNot { it.reverted }.count { it.type == "VIDEO" }

    private fun waitForText(text: String, timeout: Long = 10_000) =
        compose.waitUntil(timeout) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }

    private fun waitForSubstring(text: String, timeout: Long = 10_000) =
        compose.waitUntil(timeout) {
            compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty()
        }

    private fun openRecorder() {
        waitForText("$homeName vs $awayName")
        compose.onNodeWithText("$homeName vs $awayName").performClick()
        waitForText("Record")
        compose.onNodeWithText("Record").performClick()
        waitForText("Start")
        // The camera binds asynchronously; Start is disabled until it is ready.
        Thread.sleep(2_500)
    }

    @Test
    fun startPauseResumeStop_keepsOneFile() {
        openRecorder()

        // E2E-01: idle offers Start and Exit.
        compose.onNodeWithText("Start").assertIsDisplayed()
        compose.onNodeWithText("Exit").assertIsDisplayed()

        compose.onNodeWithText("Start").performClick()
        waitForText("Pause")
        compose.onNodeWithText("Stop").assertIsDisplayed()
        waitForSubstring("● REC")

        // The game clock follows the recording. Compose's test clock only advances while the
        // rule is polling, so the tick is observed through waitUntil rather than Thread.sleep.
        Thread.sleep(3_000)
        compose.waitUntil(10_000) { game().clockRemainingMs < 8 * 60_000L }

        // E2E-02: Pause freezes the clock and keeps the same session and file.
        compose.onNodeWithText("Pause").performClick()
        waitForText("Resume")
        val pausedClock = game().clockRemainingMs
        Thread.sleep(2_000)
        assertEquals(pausedClock, game().clockRemainingMs)

        compose.onNodeWithText("Resume").performClick()
        waitForText("Pause")
        Thread.sleep(2_000)

        // E2E-03: Stop finalizes automatically and returns to idle, no Save button.
        compose.onNodeWithText("Stop").performClick()
        waitForText("Ready", 30_000)
        compose.onNodeWithText("Start").assertIsDisplayed()
        compose.onNodeWithText("Exit").assertIsDisplayed()
        assertTrue(compose.onAllNodesWithText("Save").fetchSemanticsNodes().isEmpty())
        // One finished file, one Plays entry, nothing left unfinalized.
        assertEquals(1, videoPlays())
        assertTrue(db.orphanSegments(gameId).isEmpty())
    }

    @Test
    fun stopWhilePaused_thenSecondFile() {
        openRecorder()

        // E2E-04: Stop straight from paused, without resuming first.
        compose.onNodeWithText("Start").performClick()
        waitForText("Pause")
        Thread.sleep(2_000)
        compose.onNodeWithText("Pause").performClick()
        waitForText("Resume")
        compose.onNodeWithText("Stop").performClick()
        waitForText("Ready", 30_000)
        assertEquals(1, videoPlays())

        // E2E-05: Start again creates a second independent file and a second Plays entry.
        compose.onNodeWithText("Start").performClick()
        waitForText("Pause")
        Thread.sleep(2_000)
        compose.onNodeWithText("Stop").performClick()
        waitForText("Ready", 30_000)
        assertEquals(2, videoPlays())
        assertTrue(db.orphanSegments(gameId).isEmpty())

        compose.onNodeWithText("Exit").performClick()
        waitForText("Record")
    }

    @Test
    fun scoreMode_runsAndPausesTheClock() {
        // Score-only mode has no camera, but the same two buttons still drive the game clock.
        waitForText("$homeName vs $awayName")
        compose.onNodeWithText("$homeName vs $awayName").performClick()
        waitForText("Score")
        compose.onNodeWithText("Score").performClick()
        waitForText("Start")

        compose.onNodeWithText("Start").performClick()
        waitForText("Pause")
        // Position 2 mirrors the recording mode: Stop while the session runs, Exit only when idle.
        compose.onNodeWithText("Stop").assertIsDisplayed()
        assertTrue(compose.onAllNodesWithText("Exit").fetchSemanticsNodes().isEmpty())
        compose.waitUntil(10_000) { game().clockRemainingMs < 8 * 60_000L }

        compose.onNodeWithText("Pause").performClick()
        waitForText("Resume")
        val pausedClock = game().clockRemainingMs
        Thread.sleep(2_000)
        assertEquals(pausedClock, game().clockRemainingMs)

        // Stop ends the clock session, returns to idle, and records nothing.
        compose.onNodeWithText("Stop").performClick()
        waitForText("Ready")
        compose.onNodeWithText("Start").assertIsDisplayed()
        assertEquals(0, videoPlays())
        compose.onNodeWithText("Exit").performClick()
        waitForText("Score")
    }

    @Test
    fun exitIdle_backBlocked_rapidTaps() {
        openRecorder()

        // E2E-07: Exit from idle goes back to the game detail and records nothing.
        compose.onNodeWithText("Exit").performClick()
        waitForText("Record")
        assertEquals("READY", game().status)
        assertEquals(0, videoPlays())

        compose.onNodeWithText("Record").performClick()
        waitForText("Start")
        Thread.sleep(2_500)

        // E2E-09: rapid Start taps create exactly one session.
        compose.onNodeWithText("Start").performClick()
        repeat(2) { runCatching { compose.onNodeWithText("Start").performClick() } }
        waitForText("Pause")

        // E2E-08: no Exit while recording; the back key is blocked with a prompt.
        assertTrue(compose.onAllNodesWithText("Exit").fetchSemanticsNodes().isEmpty())
        Espresso.pressBack()
        waitForText("Recording in progress")
        compose.onNodeWithTag("stop_first_ok").performClick()
        compose.onNodeWithText("Stop").assertIsDisplayed()

        // E2E-10: rapid Stop taps close the file once and add one Plays entry.
        Thread.sleep(2_000)
        compose.onNodeWithText("Stop").performClick()
        repeat(2) { runCatching { compose.onNodeWithText("Stop").performClick() } }
        waitForText("Ready", 30_000)
        assertEquals(1, videoPlays())
        assertTrue(db.orphanSegments(gameId).isEmpty())

        compose.onNodeWithText("Exit").performClick()
        waitForText("Record")
    }
}
