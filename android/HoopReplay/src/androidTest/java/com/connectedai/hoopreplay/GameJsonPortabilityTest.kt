package com.connectedai.hoopreplay

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GameJsonPortabilityTest {
    @Test
    fun importReusesMatchingTeamsAndKeepsGameClock() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val db=HoopDb(context)
        val suffix=System.currentTimeMillis()
        val home=db.addTeam("Json Home $suffix")
        val away=db.addTeam("Json Away $suffix")
        val player=db.addPlayer(home,"Sample Player","23")
        val gameId=db.addGame("Json Export Verification",home,away,1_780_537_800_000L,"FHD",4,12*60_000L)
        db.addEvent(gameId,home,player,"PTS_3",3,1,600_000L,1,2_000L,2_000L)
        db.addEvent(gameId,away,null,"REB",1,2,590_000L,1,12_000L,12_000L)

        val snapshot=db.exportGameJson(db.games().first{it.id==gameId})
        val teamsBefore=db.teams().size
        val imported=db.importGameJson(JSONObject(snapshot.toString()))

        check(db.teams().size==teamsBefore){"Matching team names must not create teams"}
        check(imported.createdTeams==0&&imported.createdPlayers==0){"Nothing should be created: $imported"}
        val copied=db.events(imported.gameId)
        check(copied.size==2){"Expected 2 imported plays, got ${copied.size}"}
        val three=copied.first{it.type=="PTS_3"}
        check(three.period==1&&three.gameClockMs==600_000L){"Game clock lost: $three"}
        check(three.playerId==player){"Player #23 should map back to the same roster entry"}
        check(three.finalVideoTimeMs==0L&&three.segmentTimeMs==0L){"Video timestamps must be dropped: $three"}
        val rebound=copied.first{it.type=="REB"}
        check(rebound.period==2&&rebound.playerId==null){"Team rebound on the away side must survive: $rebound"}
        val game=db.games().first{it.id==imported.gameId}
        check(game.homeName=="Json Home $suffix"&&game.awayName=="Json Away $suffix"){"Sides swapped: $game"}
    }

    @Test
    fun writesAndReadsBackTheDownloadedFile() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val db=HoopDb(context)
        val suffix=System.currentTimeMillis()
        val home=db.addTeam("Json File Home $suffix")
        val away=db.addTeam("Json File Away $suffix")
        val gameId=db.addGame("Json File Verification",home,away,1_780_537_800_000L,"FHD",4,12*60_000L)
        db.addEvent(gameId,home,db.addPlayer(home,"File Player","5"),"PTS_2",2,3,400_000L,1,1_000L,1_000L)

        val fileName=exportGameJsonFile(context,db,db.games().first{it.id==gameId})
        val file=java.io.File(android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),"HoopReplay/$fileName")
        check(file.length()>100L){"Exported JSON is missing or empty: $file"}
        val imported=importGameJsonFile(context,db,android.net.Uri.fromFile(file))
        val play=db.events(imported.gameId).single()
        check(play.type=="PTS_2"&&play.period==3&&play.gameClockMs==400_000L){"Round trip lost the play clock: $play"}
    }

    @Test
    fun importCreatesMissingTeamAndJerseyNumber() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val db=HoopDb(context)
        val suffix=System.currentTimeMillis()
        val home=db.addTeam("Json Keep $suffix")
        db.addPlayer(home,"Kept Player","7")
        val away=db.addTeam("Json Drop $suffix")
        val gameId=db.addGame("Json Import Verification",home,away,1_780_537_800_000L,"FHD",4,12*60_000L)
        db.addEvent(gameId,home,db.players(home).first().id,"PTS_2",2,1,500_000L,1,1_000L,1_000L)

        val snapshot=JSONObject(db.exportGameJson(db.games().first{it.id==gameId}).toString())
        snapshot.getJSONObject("away").put("name","Json Brand New $suffix")
        snapshot.getJSONArray("events").getJSONObject(0).put("playerNumber","99").put("playerName","Newcomer")

        val imported=db.importGameJson(snapshot)
        check(imported.createdTeams==1){"Unknown team name must be created: $imported"}
        check(imported.createdPlayers==1){"Unknown jersey number must be created: $imported"}
        val game=db.games().first{it.id==imported.gameId}
        check(game.awayName=="Json Brand New $suffix"){"New team not attached: $game"}
        val scorer=db.players(game.homeId).first{it.number=="99"}
        check(db.events(imported.gameId).single().playerId==scorer.id){"Play must point at the created #99"}
        check(db.players(game.homeId).any{it.number=="7"}){"Existing roster must be preserved"}
    }
}
