package com.connectedai.hoopreplay

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** Runs the cross-platform fixture so Android cuts exactly the clips the Web and iOS cut. */
class HighlightClipsTest {
    @Test
    fun matchesSharedFixture() {
        val fixture = JSONObject(File("../../web/lib/highlight-clips.fixture.json").readText())
        val segments = fixture.getJSONArray("segments").let { a -> (0 until a.length()).map { a.getJSONObject(it).let { s -> VideoSegment(s.getInt("sequence"), "", s.getLong("duration_ms")) } } }
        val events = fixture.getJSONArray("events").let { a -> (0 until a.length()).map { i -> a.getJSONObject(i).let { e ->
            StatEvent(i.toString(), "1", e.get("team_id").toString(), if (e.isNull("player_id")) null else e.get("player_id").toString(), e.getString("type"), 0, 1, 0, e.getInt("segment"), e.getLong("segment_time_ms"), 0, e.getInt("reverted") != 0)
        } } }
        val cases = fixture.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val t = c.getJSONObject("target")
            val target = if (t.has("player_id")) HighlightTarget.PlayerTarget(t.get("player_id").toString()) else HighlightTarget.TeamTarget(t.get("team_id").toString())
            val expected = c.getJSONArray("clips").let { a -> (0 until a.length()).map { a.getJSONObject(it).let { k -> Clip(k.getInt("segment"), k.getLong("start_ms"), k.getLong("end_ms")) } } }
            assertEquals(c.getString("name"), expected, highlightClips(events, segments, target))
        }
    }
}
