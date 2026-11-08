package com.connectedai.hoopreplay

import android.os.Environment
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdfExportTest {
    @Test
    fun exportsStatisticsPdf() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val db=HoopDb(context)
        val suffix=System.currentTimeMillis()
        val home=db.addTeam("PDF Home $suffix")
        val away=db.addTeam("PDF Away $suffix")
        val player=db.addPlayer(home,"Sample Player","23")
        val gameId=db.addGame("PDF Export Verification",home,away,1_780_537_800_000L,"FHD",4,12*60_000L)
        db.addEvent(gameId,home,player,"PTS_3",3,1,600_000L,1,2_000L,2_000L)
        db.addEvent(gameId,home,player,"REB",1,1,590_000L,1,12_000L,12_000L)
        val fileName=exportStatsPdf(context,db,db.games().first{it.id==gameId})
        val file=java.io.File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),"HoopReplay/$fileName")
        check(file.length()>500L){"Generated PDF is missing or empty: $file"}
    }
}
