package com.connectedai.hoopreplay

import android.Manifest
import android.app.NotificationManager
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.os.StatFs
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.pdf.PdfDocument
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import android.view.ScaleGestureDetector
import android.view.Gravity
import android.view.ViewGroup
import android.os.Build
import android.view.Surface
import android.view.WindowManager
import android.widget.Toast
import android.widget.NumberPicker
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraEffect
import androidx.camera.core.UseCaseGroup
import androidx.camera.effects.OverlayEffect
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.MediaStoreOutputOptions
import androidx.camera.video.PendingRecording
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBackIos
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SportsBasketball
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

private val Orange = Color(0xFFFF7A00)
private val Ink = Color(0xFF0B0F14)
private val AppBackground = Color(0xFFF5F6F8)
private val ScoreboardBackground = Color(0x4D1A1C20)
private val MadeGreen = Color(0xFF16A36D)
private val MissRed = Color(0xFFD63B52)
private val FreeThrowOrange = Color(0xFFC75B00)
private val ExitRed = Color(0xFFB3261E)
// Disabled toolbar buttons keep their normal border and only gray the label, so they never
// read as having disappeared.
private val DisabledLabel = Color(0xFF8F969F)
private val PanelBlue = Color(0xFFFFFFFF)
private val CardBlue = Color(0xFFFFFFFF)
private val SecondaryText = Color(0xFF5F6670)
private val VideoQualityOptions=listOf("HIGHEST" to "Device maximum","UHD" to "4K · Largest file","FHD" to "1080p · Recommended","HD" to "720p · Smaller file","SD" to "480p · Smallest file")

private fun formatGameDateTime(timestamp: Long): String =
    SimpleDateFormat("MMM d, yyyy  h:mm a", Locale.getDefault()).format(timestamp)

class MainActivity : ComponentActivity() {
    companion object {
        /** The browser's return from a Google or Apple sign-in; the home shell consumes it and finishes the sign-in. */
        val oauthCallback = mutableStateOf<Intent?>(null)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val db = HoopDb(this)
        if (intent?.data != null) oauthCallback.value = intent
        setContent { MaterialTheme(colorScheme = lightColorScheme(primary=Orange,onPrimary=Color.White,background=AppBackground,surface=CardBlue,onSurface=Ink,secondary=SecondaryText,surfaceVariant=AppBackground,surfaceContainerLowest=CardBlue,surfaceContainerLow=CardBlue,surfaceContainer=CardBlue,surfaceContainerHigh=CardBlue,surfaceContainerHighest=CardBlue)) { HoopReplay(db) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.data != null) oauthCallback.value = intent
    }
}

private sealed interface Page { data object Home:Page; data class PlayerList(val teamId:String,val back:Page = Home):Page; data class PlayerDetail(val teamId:String,val playerId:String,val back:Page):Page; data object GameForm:Page; data class GameDetail(val id:String):Page; data class Record(val id:String):Page; data class Score(val id:String):Page }
private enum class PlayerSort(val code:String, val label:String) { First("first", "First name"), Last("last", "Last name"), Number("number", "Jersey number") }
private fun savedPlayerSort(context:Context)=PlayerSort.entries.firstOrNull{it.code==context.getSharedPreferences("hoopreplay",Context.MODE_PRIVATE).getString("player_sort","number")}?:PlayerSort.Number
private fun savePlayerSort(context:Context, sort:PlayerSort)=context.getSharedPreferences("hoopreplay",Context.MODE_PRIVATE).edit().putString("player_sort",sort.code).apply()
private enum class HomeTab(val label:String,val icon:ImageVector) { Home("Home",Icons.Filled.Home), Games("Games",Icons.Filled.SportsBasketball), Teams("Teams",Icons.Filled.Group), Settings("Settings",Icons.Filled.Settings) }

/** Name to greet the account by: the display name it chose, or a readable form of its email. */
private fun accountLabel(email:String):String {
    val local=email.substringBefore('@')
    if(local.isBlank())return t("Coach")
    return local.split('.','_','-').filter{it.isNotBlank()}.joinToString(" "){it.capitalizeInitial()}
}
private fun accountInitials(name:String):String =
    name.trim().split(" ").filter{it.isNotBlank()}.take(2).map{it.first().uppercaseChar()}.joinToString("").ifBlank{"?"}

/** Google's white "Continue with Google" button, in the style of its branding guidelines. */
@Composable private fun GoogleSignInButton(enabled:Boolean,onClick:()->Unit) {
    OutlinedButton(onClick=onClick,enabled=enabled,modifier=Modifier.fillMaxWidth().height(44.dp),shape=RoundedCornerShape(8.dp),border=BorderStroke(1.dp,Color(0xFFDADCE0)),colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.White,contentColor=Ink,disabledContainerColor=Color.White,disabledContentColor=Color.Gray)) {
        Text("G",color=Color(0xFF4285F4),style=MaterialTheme.typography.titleMedium);Spacer(Modifier.width(8.dp));Text(t("Continue with Google"),maxLines=1)
    }
}
/** Apple's black "Sign in with Apple" button, as its Human Interface Guidelines require. */
@Composable private fun AppleSignInButton(enabled:Boolean,onClick:()->Unit) {
    Button(onClick=onClick,enabled=enabled,modifier=Modifier.fillMaxWidth().height(44.dp),shape=RoundedCornerShape(8.dp),colors=ButtonDefaults.buttonColors(containerColor=Color.Black,contentColor=Color.White,disabledContainerColor=Color.Black,disabledContentColor=Color.Gray)) {
        Icon(appleLogo,null,Modifier.size(18.dp),tint=Color.White);Spacer(Modifier.width(8.dp));Text(t("Sign in with Apple"),maxLines=1)
    }
}
/** The Apple logo (Material has none); the path is the Simple Icons glyph, CC0. */
private val appleLogo:ImageVector by lazy {
    ImageVector.Builder("AppleLogo",24.dp,24.dp,24f,24f).addPath(
        pathData=addPathNodes("M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"),
        fill=SolidColor(Color.White)).build()
}

@Composable private fun HoopReplay(db:HoopDb) {
    val context=LocalContext.current
    remember { I18n.start(context); true }
    val language=I18n.language
    var playerSort by remember { mutableStateOf(savedPlayerSort(context)) }
    PlayerSortPreference.current=playerSort
    var page by remember { mutableStateOf<Page>(Page.Home) }
    var tab by remember { mutableStateOf(HomeTab.Home) }
    // Orientation is a hard rule that ignores the device's auto-rotate setting: the live
    // score/record screens are locked to landscape, every other page is locked to portrait.
    // Re-applied on every page change so a screen that rotated temporarily (full-screen
    // statistics) can never leave the next page in the wrong orientation.
    LaunchedEffect(page){(context as? ComponentActivity)?.requestedOrientation=if(page is Page.Record||page is Page.Score)ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT}
    when(val p=page) {
        Page.Home -> MainShell(db, tab, language, onLanguage={I18n.set(context,it)}, playerSort=playerSort, onPlayerSort={playerSort=it;PlayerSortPreference.current=it;savePlayerSort(context,it)}, onTab={tab=it}, onGame={page=Page.GameForm}, onOpen={page=Page.GameDetail(it)}, onOpenTeam={page=Page.PlayerList(it)})
        is Page.PlayerList -> db.teams().firstOrNull{it.id==p.teamId}?.let{team->PlayerListScreen(db,team,onBack={page=p.back},onTeamDeleted={page=p.back},onPlayer={page=Page.PlayerDetail(team.id,it,p)})}
        is Page.PlayerDetail -> db.teams().firstOrNull{it.id==p.teamId}?.let{team->db.players(team.id).firstOrNull{it.id==p.playerId}?.let{player->PlayerDetailScreen(db,team,player,onBack={page=p.back},onDeleted={page=p.back})}}
        Page.GameForm -> GameForm(db){page=Page.Home}
        is Page.GameDetail -> db.games().firstOrNull{it.id==p.id}?.let{game->GameDetailScreen(db,game,onBack={page=Page.Home},onRecord={page=Page.Record(game.id)},onScore={page=Page.Score(game.id)},onDeleted={page=Page.Home},onOpenTeam={page=Page.PlayerList(it,Page.GameDetail(game.id))})}
        is Page.Record -> db.games().firstOrNull{it.id==p.id&&it.ownerId==null}?.let { RecorderScreen(db,it,onOpenTeam={teamId->page=Page.PlayerList(teamId,Page.Record(p.id))}){page=Page.GameDetail(p.id)} }
        is Page.Score -> db.games().firstOrNull{it.id==p.id&&it.ownerId==null}?.let { RecorderScreen(db,it,scoreOnly=true,onOpenTeam={teamId->page=Page.PlayerList(teamId,Page.Score(p.id))}){page=Page.GameDetail(p.id)} }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun MainShell(db:HoopDb,tab:HomeTab,language:AppLanguage,onLanguage:(AppLanguage)->Unit,playerSort:PlayerSort,onPlayerSort:(PlayerSort)->Unit,onTab:(HomeTab)->Unit,onGame:()->Unit,onOpen:(String)->Unit,onOpenTeam:(String)->Unit) {
    var refresh by remember { mutableIntStateOf(0) };var query by remember{mutableStateOf("")};var syncing by remember{mutableStateOf(false)};var syncMessage by remember{mutableStateOf<String?>(null)};var showAuth by remember{mutableStateOf(false)};var showAccount by remember{mutableStateOf(false)};var pendingDelete by remember{mutableStateOf<Game?>(null)};val context=LocalContext.current;var email by remember{mutableStateOf(HoopSync.signedInEmail(context))};var password by remember{mutableStateOf(HoopSync.rememberedPassword(context))};var passwordVisible by remember{mutableStateOf(false)};var signUp by remember{mutableStateOf(false)};var signedIn by remember{mutableStateOf(HoopSync.isSignedIn(context))};val scope=rememberCoroutineScope();val games=remember(refresh){db.games()}; val teams=remember(refresh){db.teams()};val playerCount=remember(refresh){teams.sumOf{db.players(it.id).size}};val shown=remember(games,query){val q=query.trim();if(q.isEmpty())games else games.filter{it.title.contains(q,true)||it.homeName.contains(q,true)||it.awayName.contains(q,true)}}
    var languageMenuOpen by remember { mutableStateOf(false) }
    var playerSortMenuOpen by remember { mutableStateOf(false) }
    val accountEmail=if(signedIn)HoopSync.signedInEmail(context) else ""
    val accountName=(if(signedIn)HoopSync.signedInName(context) else "").ifBlank{accountLabel(accountEmail)}
    val importGame=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()){uri->
        if(uri!=null)scope.launch{
            val result=withContext(Dispatchers.IO){runCatching{importGameJsonFile(context,db,uri)}}
            syncMessage=result.fold(
                {"Imported ${it.events} plays, ${it.createdTeams} new teams, ${it.createdPlayers} new players"},
                {t("Import failed: {message}","message" to it.message)}
            )
            refresh++
        }
    }
    val runSync:(String,suspend ()->Unit)->Unit={label,work->
        if(!HoopSync.configured)syncMessage="Add Supabase URL, publishable key, and sync space to Gradle properties"
        else if(!HoopSync.isSignedIn(context))showAuth=true
        else scope.launch{
            syncing=true
            syncMessage=runCatching{work();refresh++;"$label complete"}.getOrElse{
                // A failed refresh-token exchange clears the stored session in HoopSync.
                // Mirror that result in Compose so the account controls recover immediately.
                signedIn=HoopSync.isSignedIn(context)
                t("$label failed: {message}","message" to it.message)
            }
            syncing=false
        }
    }
    // Sign-out uploads first, then forgets the account and its games so the next account starts empty.
    val signOut:()->Unit={
        scope.launch{
            syncing=true
            val uploaded=HoopSync.signOut(context,db)
            signedIn=false;email="";password="";passwordVisible=false;refresh++
            syncMessage=if(uploaded)"Signed out" else "Signed out. Games that could not be uploaded stay on this device until this account signs in again"
            syncing=false
        }
    }
    Box(Modifier.fillMaxSize()) {
    Scaffold(
        topBar={TopAppBar(title={Text("HoopReplay")},actions={
            if(signedIn)Box{
                IconButton(onClick={showAccount=true}){Box(Modifier.size(38.dp).background(Orange,CircleShape),contentAlignment=Alignment.Center){Text(accountInitials(accountName),color=Color.White,style=MaterialTheme.typography.labelLarge)}}
                DropdownMenu(expanded=showAccount,onDismissRequest={showAccount=false}){
                    Row(Modifier.padding(horizontal=16.dp,vertical=10.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){
                        Box(Modifier.size(40.dp).background(Orange,CircleShape),contentAlignment=Alignment.Center){Text(accountInitials(accountName),color=Color.White,style=MaterialTheme.typography.labelLarge)}
                        Column{Text(accountName,style=MaterialTheme.typography.titleSmall);Text(accountEmail,color=SecondaryText,style=MaterialTheme.typography.bodySmall)}
                    }
                    HorizontalDivider()
                    DropdownMenuItem(text={Text(t("Account settings"))},leadingIcon={Icon(Icons.Filled.Person,null)},trailingIcon={Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight,null)},onClick={showAccount=false;onTab(HomeTab.Settings)})
                    DropdownMenuItem(text={Text(t("Sync status"))},leadingIcon={Icon(Icons.Filled.CloudQueue,null)},trailingIcon={Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight,null)},onClick={showAccount=false;onTab(HomeTab.Settings)})
                    HorizontalDivider()
                    DropdownMenuItem(text={Text(t("Sign out"),color=MaterialTheme.colorScheme.error)},leadingIcon={Icon(Icons.AutoMirrored.Filled.Logout,null,tint=MaterialTheme.colorScheme.error)},onClick={showAccount=false;signOut()})
                }
            } else TextButton(onClick={showAuth=true}){Text(t("Sign in"),color=Orange)}
        })},
        bottomBar={NavigationBar(containerColor=Color.White){HomeTab.entries.forEach{entry->NavigationBarItem(selected=tab==entry,onClick={onTab(entry)},icon={Icon(entry.icon,null)},label={Text(t(entry.label))},colors=NavigationBarItemDefaults.colors(selectedIconColor=Orange,selectedTextColor=Orange,indicatorColor=Color.Transparent))}}},
        floatingActionButton={if(tab==HomeTab.Games)Button(onClick=onGame,enabled=teams.size>=2){Text(t("Create Game"))}}
    ){ pad ->
        Column(Modifier.padding(pad).padding(horizontal=20.dp).fillMaxSize()) {
            when(tab) {
                HomeTab.Home -> {
                    Spacer(Modifier.height(12.dp))
                    Text(if(signedIn)t("Welcome back, {name}","name" to accountName) else t("Welcome back"),style=MaterialTheme.typography.headlineMedium)
                    Text(t("Every game leaves a trail."),color=SecondaryText); Spacer(Modifier.height(16.dp))
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp)){
                        Card(onClick={onTab(HomeTab.Teams)},modifier=Modifier.weight(1f)){Row(Modifier.padding(16.dp).fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){Icon(Icons.Filled.Group,null,tint=Orange,modifier=Modifier.size(30.dp));Column{Text("${teams.size}",style=MaterialTheme.typography.headlineSmall);Text(t("Teams"),color=SecondaryText,style=MaterialTheme.typography.bodyMedium)}}}
                        Card(onClick={onTab(HomeTab.Teams)},modifier=Modifier.weight(1f)){Row(Modifier.padding(16.dp).fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){Icon(Icons.Filled.Person,null,tint=Orange,modifier=Modifier.size(30.dp));Column{Text("$playerCount",style=MaterialTheme.typography.headlineSmall);Text(t("Players"),color=SecondaryText,style=MaterialTheme.typography.bodyMedium)}}}
                    }
                    Spacer(Modifier.height(12.dp)); Card(Modifier.fillMaxWidth()){Row(Modifier.padding(16.dp).fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){Icon(if(signedIn)Icons.Filled.CloudDone else Icons.Filled.CloudQueue,null,tint=Orange,modifier=Modifier.size(30.dp));Column(Modifier.weight(1f)){Text(t("Cloud sync"),style=MaterialTheme.typography.titleMedium);Text(if(signedIn)t("Signed in") else t("Local only"),color=SecondaryText,style=MaterialTheme.typography.bodySmall)};TextButton(enabled=!syncing,onClick={runSync("Download"){HoopSync.pull(context,db)}}){Text(if(syncing)"…" else t("Download"),color=Orange,maxLines=1)};TextButton(enabled=!syncing,onClick={runSync("Upload"){HoopSync.push(context,db)}}){Text(if(syncing)"…" else t("Upload"),color=Orange,maxLines=1)}}}
                    syncMessage?.let{Text(t(it),color=if(it.endsWith("complete")||it.startsWith("Imported"))Orange else MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)}
                }
                HomeTab.Games -> {
                    Spacer(Modifier.height(12.dp))
                    Text(t("Games"),style=MaterialTheme.typography.headlineSmall); Spacer(Modifier.height(12.dp))
                    OutlinedTextField(query,{query=it},Modifier.fillMaxWidth(),singleLine=true,leadingIcon={Icon(Icons.Filled.Search,null)},placeholder={Text(t("Search games…"))})
                    Spacer(Modifier.height(10.dp))
                    if(shown.isEmpty())Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.Center){
                        Column(horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(10.dp)){
                            Icon(Icons.Filled.SportsBasketball,null,tint=Orange,modifier=Modifier.size(72.dp))
                            Text(if(query.isNotBlank())t("No games found") else t("No games yet"),style=MaterialTheme.typography.titleLarge)
                            Text(if(teams.size<2)t("Add two teams first, then create your first game.") else t("Create your first game to start tracking highlights."),color=SecondaryText,textAlign=TextAlign.Center)
                            Button(onClick={if(teams.size<2)onTab(HomeTab.Teams) else onGame},modifier=Modifier.height(48.dp)){Text(if(teams.size<2)t("Add teams") else "+  ${t("Create Game")}")}
                        }
                    }
                    else LazyColumn(Modifier.weight(1f), verticalArrangement=Arrangement.spacedBy(10.dp)) {
                        items(items=shown, key={it.id}) { g ->
                            Card(onClick={onOpen(g.id)}, modifier=Modifier.fillMaxWidth()) {
                                Row(Modifier.padding(16.dp).fillMaxWidth(), horizontalArrangement=Arrangement.spacedBy(8.dp), verticalAlignment=Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text(g.title, style=MaterialTheme.typography.titleMedium)
                                        Text(formatGameDateTime(g.scheduledAt), color=Orange)
                                        Row(verticalAlignment=Alignment.CenterVertically) {
                                            // Plain text on purpose: a tappable team name inside the card was too easy to hit
                                            // when aiming for the game itself.
                                            Text(g.homeName, style=MaterialTheme.typography.bodyMedium, maxLines=1)
                                            Text("  ${g.homeScore} : ${g.awayScore}  ", color=SecondaryText)
                                            Text(g.awayName, style=MaterialTheme.typography.bodyMedium, maxLines=1)
                                        }
                                        Text(t(statusLabel(g.status)), color=Orange)
                                    }
                                }
                            }
                        }
                    }
                }
                HomeTab.Teams -> TeamsTab(db,refresh,onChanged={refresh++},onOpen=onOpenTeam)
                HomeTab.Settings -> Column(Modifier.verticalScroll(rememberScrollState())){
                    Spacer(Modifier.height(12.dp)); Text(t("Settings"),style=MaterialTheme.typography.headlineSmall); Spacer(Modifier.height(12.dp))
                    Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                        Text(t("Interface Language"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                        ExposedDropdownMenuBox(expanded=languageMenuOpen,onExpandedChange={languageMenuOpen=!languageMenuOpen}){
                            OutlinedTextField(value=language.nativeName,onValueChange={},readOnly=true,singleLine=true,modifier=Modifier.menuAnchor(MenuAnchorType.PrimaryNotEditable).fillMaxWidth(),trailingIcon={ExposedDropdownMenuDefaults.TrailingIcon(languageMenuOpen)})
                            ExposedDropdownMenu(expanded=languageMenuOpen,onDismissRequest={languageMenuOpen=false}){
                                AppLanguage.entries.forEach { option -> DropdownMenuItem(text={Text(option.nativeName)},onClick={onLanguage(option);languageMenuOpen=false}) }
                            }
                        }
                    }}
                    Spacer(Modifier.height(12.dp))
                    Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                        Text(t("Player selection order"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                        Text(t("Choose how players are ordered in selection dialogs."),color=SecondaryText,style=MaterialTheme.typography.bodySmall)
                        ExposedDropdownMenuBox(expanded=playerSortMenuOpen,onExpandedChange={playerSortMenuOpen=!playerSortMenuOpen}){
                            OutlinedTextField(value=t(playerSort.label),onValueChange={},readOnly=true,singleLine=true,modifier=Modifier.menuAnchor(MenuAnchorType.PrimaryNotEditable).fillMaxWidth(),trailingIcon={ExposedDropdownMenuDefaults.TrailingIcon(playerSortMenuOpen)})
                            ExposedDropdownMenu(expanded=playerSortMenuOpen,onDismissRequest={playerSortMenuOpen=false}){
                                PlayerSort.entries.forEach { option -> DropdownMenuItem(text={Text(t(option.label))},onClick={onPlayerSort(option);playerSortMenuOpen=false}) }
                            }
                        }
                    }}
                    Spacer(Modifier.height(12.dp))
                    Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                        Text(t("Account"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                        if(signedIn){
                            SettingsRow(t("Name"),accountName); SettingsRow(t("Email"),accountEmail)
                        } else {
                            Text(t("Sign in to sync games across mobile and Web."),color=SecondaryText,style=MaterialTheme.typography.bodyMedium)
                            Button(onClick={showAuth=true}){Text(t("Sign in"))}
                        }
                    }}
                    Spacer(Modifier.height(12.dp))
                    Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                        Text(t("Sync"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                        SettingsRow(t("Status"),if(!HoopSync.configured)t("Setup required") else if(signedIn)t("Signed in") else t("Local only"))
                        syncMessage?.let{Text(t(it),color=if(it.endsWith("complete")||it.startsWith("Imported"))Orange else MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)}
                        Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){
                            OutlinedButton(enabled=!syncing,onClick={runSync("Download"){HoopSync.pull(context,db)}},modifier=Modifier.weight(1f)){Text(if(syncing)"…" else t("Download"),maxLines=1)}
                            OutlinedButton(enabled=!syncing,onClick={runSync("Upload"){HoopSync.push(context,db)}},modifier=Modifier.weight(1f)){Text(if(syncing)"…" else t("Upload"),maxLines=1)}
                        }
                    }}
                    Spacer(Modifier.height(12.dp))
                    Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
                        Text(t("Upload recordings"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                        Text(t("Whole-game recordings upload to the cloud so highlights can be cut on HoopReplay Web."),color=SecondaryText,style=MaterialTheme.typography.bodyMedium)
                        var uploadChoice by remember{mutableStateOf(VideoUpload.uploadRecordings(context))}
                        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp)){
                            UploadRecordings.entries.forEach{choice->FilterChip(selected=uploadChoice==choice,onClick={uploadChoice=choice;VideoUpload.setUploadRecordings(context,choice)},label={Text(t(choice.label),maxLines=1,softWrap=false)},modifier=Modifier.weight(1f))}
                        }
                    }}
                    Spacer(Modifier.height(12.dp))
                    Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
                        Text(t("Import"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                        Text(t("Bring in a game exported as JSON from HoopReplay Web or another device. Missing teams and players are created automatically."),color=SecondaryText,style=MaterialTheme.typography.bodyMedium)
                        Button(onClick={importGame.launch(arrayOf("application/json","text/plain","*/*"))}){Text(t("Choose JSON file"),maxLines=1)}
                        syncMessage?.let{Text(t(it),color=if(it.startsWith("Imported"))Orange else MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)}
                    }}
                    Spacer(Modifier.height(12.dp))
                    Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                        Text(t("Storage"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                        SettingsRow(t("Teams"),"${teams.size}"); SettingsRow(t("Players"),"$playerCount"); SettingsRow(t("Games"),"${games.size}")
                    }}
                    if(signedIn){
                        Spacer(Modifier.height(12.dp))
                        Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                            Text(t("Account actions"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                            Button(enabled=!syncing,onClick={signOut()},colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error,contentColor=Color.White)){Text(t("Sign out"),maxLines=1)}
                        }}
                    }
                    Spacer(Modifier.height(12.dp))
                    // The installed build's version sits at the very bottom so support questions can
                    // be answered from a screenshot of this screen.
                    Card(Modifier.fillMaxWidth()){Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                        Text(t("About"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                        SettingsRow(t("Version"),"${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                    }}
                    Spacer(Modifier.height(24.dp))
                }
            }
        }
    }
    // The browser comes back from a Google or Apple sign-in; finish it and sync like a password sign-in.
    val oauthIntent by MainActivity.oauthCallback
    LaunchedEffect(oauthIntent?.data?.toString()){
        val intent=oauthIntent?:return@LaunchedEffect
        val isCallback=runCatching{HoopSync.isOAuthCallback(intent)}.getOrElse{syncMessage=t("Sign in failed: {message}","message" to it.message);showAuth=true;MainActivity.oauthCallback.value=null;return@LaunchedEffect}
        if(!isCallback)return@LaunchedEffect
        syncing=true;showAuth=true
        try {
            syncMessage=runCatching{HoopSync.completeOAuthSignIn(context,intent);signedIn=true;showAuth=false;passwordVisible=false;email=HoopSync.signedInEmail(context);HoopSync.pull(context,db);HoopSync.push(context,db);refresh++;"Sync complete"}.getOrElse{t("Sign in failed: {message}","message" to it.message)}
        } finally {
            syncing=false
            MainActivity.oauthCallback.value=null
        }
    }
    if(showAuth)AlertDialog(onDismissRequest={showAuth=false;passwordVisible=false},title={Text(if(signUp)t("Create sync account") else t("Sign in to sync"))},text={Column(verticalArrangement=Arrangement.spacedBy(8.dp)){Text(t("Games stay on this device until you choose to sync."),color=Color.Gray);GoogleSignInButton(enabled=!syncing){syncMessage=null;runCatching{HoopSync.beginGoogleSignIn(context)}.onFailure{syncMessage=t("Sign in failed: {message}","message" to it.message)}};AppleSignInButton(enabled=!syncing){syncMessage=null;runCatching{HoopSync.beginAppleSignIn(context)}.onFailure{syncMessage=t("Sign in failed: {message}","message" to it.message)}};Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)){HorizontalDivider(Modifier.weight(1f));Text(t("or use email"),color=Color.Gray,style=MaterialTheme.typography.bodySmall);HorizontalDivider(Modifier.weight(1f))};OutlinedTextField(email,{email=it},singleLine=true,label={Text(t("Email"))});OutlinedTextField(password,{password=it},singleLine=true,label={Text(t("Password"))},visualTransformation=if(passwordVisible)VisualTransformation.None else PasswordVisualTransformation(),trailingIcon={TextButton(onClick={passwordVisible=!passwordVisible}){Text(if(passwordVisible)t("Hide") else t("Show"),color=Orange)}});TextButton(onClick={signUp=!signUp;syncMessage=null}){Text(if(signUp)t("Already have an account? Sign in") else t("New here? Create account"))};syncMessage?.takeIf{!it.endsWith("complete")}?.let{Text(t(it),color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodyMedium)}}},confirmButton={Button(enabled=!syncing&&email.contains('@')&&password.length>=6,onClick={scope.launch{syncing=true;syncMessage=runCatching{HoopSync.authenticate(context,email,password,signUp);signedIn=true;showAuth=false;passwordVisible=false;HoopSync.pull(context,db);HoopSync.push(context,db);refresh++;"Sync complete"}.getOrElse{if(it.message?.startsWith("Check your email")==true){signUp=false;password="";passwordVisible=false;it.message}else t("Sign in failed: {message}","message" to it.message)};syncing=false}}){Text(if(syncing)t("Please wait…") else if(signUp)t("Create account") else t("Sign in & sync"))}},dismissButton={Button(enabled=!syncing,onClick={showAuth=false;passwordVisible=false}){Text(t("Cancel"))}})
    pendingDelete?.let{game->AlertDialog(onDismissRequest={pendingDelete=null},title={Text(t("Delete Game?"))},text={Text(t("This will delete scores, stats, and recording segment records for {title}. This cannot be undone.","title" to game.title))},confirmButton={Button(colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error),onClick={db.deleteGame(game.id);pendingDelete=null;refresh++}){Text(t("Delete"))}},dismissButton={Button(onClick={pendingDelete=null}){Text(t("Cancel"))}})}
    if(syncing)Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha=0.16f)).clickable{},contentAlignment=Alignment.Center){Card{Row(Modifier.padding(horizontal=24.dp,vertical=18.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){CircularProgressIndicator(color=Orange,modifier=Modifier.size(28.dp),strokeWidth=3.dp);Text(t("Syncing…"))}}}
    }
}

@Composable private fun SettingsRow(label:String,value:String){
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically){
        Text(label,color=SecondaryText,style=MaterialTheme.typography.bodyMedium)
        Text(value,style=MaterialTheme.typography.bodyMedium,maxLines=1)
    }
}

private fun rosterOrder(players:List<Player>):List<Player> = players.sortedWith(
    when(PlayerSortPreference.current){
        PlayerSort.First -> compareBy({ it.name.trim().substringBefore(' ').lowercase() }, { it.name.lowercase() }, { it.number.toIntOrNull() ?: Int.MAX_VALUE })
        PlayerSort.Last -> compareBy({ it.name.trim().substringAfter(' ', "").lowercase() }, { it.name.trim().substringBefore(' ').lowercase() }, { it.number.toIntOrNull() ?: Int.MAX_VALUE })
        PlayerSort.Number -> compareBy({ it.number.isBlank() }, { it.number.toIntOrNull() ?: Int.MAX_VALUE }, { it.name.trim().substringBefore(' ').lowercase() }, { it.name.lowercase() })
    }
)

private fun playerSelectionLabel(player:Player, players:List<Player>):String {
    val name=player.name.trim()
    if(name.isBlank()) return player.label
    val first=name.substringBefore(' ').trim()
    val last=name.substringAfter(' ', "").trim()
    val sameFirst=players.filter{it.name.trim().substringBefore(' ').equals(first,true)}
    if(sameFirst.size<=1) return if(player.number.isBlank()) first else "#${player.number} $first"
    if(last.isBlank()) return player.label
    val initial=last.first().uppercaseChar()
    val sameInitial=sameFirst.count{it.name.trim().substringAfter(' ', "").trim().firstOrNull()?.uppercaseChar()==initial}
    val display=if(sameInitial>1) name else "$first $initial."
    return if(player.number.isBlank()) display else "#${player.number} $display"
}

private object PlayerSortPreference { var current:PlayerSort = PlayerSort.Number }

// Full-screen statistics rotate to landscape; leaving full screen restores the orientation the host
// screen had before (portrait for normal pages, landscape when opened from the recorder), so the
// live score/record screens are never flipped back to portrait by closing the stats panel.
private fun setStatsFullscreen(context:Context,view:android.view.View,enabled:Boolean,baseOrientation:Int){
    (context as? ComponentActivity)?.requestedOrientation=if(enabled)ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else baseOrientation
    view.systemUiVisibility=if(enabled) android.view.View.SYSTEM_UI_FLAG_FULLSCREEN or android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY else 0
}

@Composable private fun ColumnScope.TeamsTab(db:HoopDb,refresh:Int,onChanged:()->Unit,onOpen:(String)->Unit) {
    var query by remember{mutableStateOf("")};var newName by remember{mutableStateOf("")};var showAdd by remember{mutableStateOf(false)}
    val teams=remember(refresh){db.teams()};val shown=remember(teams,query){teams.filter{it.name.contains(query.trim(),ignoreCase=true)}}
    Spacer(Modifier.height(12.dp))
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically){
        Column {
            Text(t("Teams & Players"),style=MaterialTheme.typography.headlineSmall)
            Text(t("{count} teams","count" to teams.size),color=SecondaryText,style=MaterialTheme.typography.bodyMedium)
        }
        Button(onClick={showAdd=true},contentPadding=PaddingValues(horizontal=16.dp,vertical=6.dp)){Text(t("Add team"))}
    }
    Spacer(Modifier.height(12.dp))
    OutlinedTextField(query,{query=it},Modifier.fillMaxWidth(),singleLine=true,leadingIcon={Icon(Icons.Filled.Search,null)},placeholder={Text(t("Search teams…"))})
    if(shown.isEmpty())Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.Center){Text(if(query.isBlank())t("No teams yet.") else t("No teams found"),color=SecondaryText)}
    else LazyColumn(Modifier.padding(top=12.dp).weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)){items(shown,key={it.id}){team->Card(onClick={onOpen(team.id)},modifier=Modifier.fillMaxWidth()){Row(Modifier.fillMaxWidth().padding(16.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)){Column(Modifier.weight(1f)){Text(team.name,style=MaterialTheme.typography.titleMedium);Text(t("{count} players","count" to db.players(team.id).size),color=SecondaryText)}}}}}
    if(showAdd)AlertDialog(onDismissRequest={showAdd=false},title={Text(t("Add Team"))},text={OutlinedTextField(newName,{newName=it.capitalizeInitial()},singleLine=true,label={Text(t("Team name"))})},confirmButton={Button(enabled=newName.isNotBlank(),onClick={db.addTeam(newName.trim());newName="";showAdd=false;onChanged()}){Text(t("Save"))}},dismissButton={Button(onClick={showAdd=false}){Text(t("Cancel"))}})
}

@Composable private fun TeamNameLink(name:String,modifier:Modifier=Modifier,textAlign:TextAlign?=null,style:androidx.compose.ui.text.TextStyle=MaterialTheme.typography.titleMedium,maxLines:Int=2,onClick:()->Unit){
    Text(name,modifier.clickable(onClick=onClick),color=Orange,textAlign=textAlign,style=style,textDecoration=TextDecoration.Underline,maxLines=maxLines)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun GameDetailScreen(db:HoopDb,initialGame:Game,onBack:()->Unit,onRecord:()->Unit,onScore:()->Unit,onDeleted:()->Unit,onOpenTeam:(String)->Unit){
    val context=LocalContext.current
    val view=LocalView.current
    val scope=rememberCoroutineScope()
    var deleting by remember{mutableStateOf(false)}
    var ending by remember{mutableStateOf(false)}
    var exporting by remember{mutableStateOf(false)}
    var highlighting by remember{mutableStateOf(false)}
    var selectedTeam by remember{mutableIntStateOf(0)}
    var detailTab by remember{mutableIntStateOf(0)}
    var tick by remember{mutableIntStateOf(0)}
    var immersive by remember{mutableStateOf(false)}
    var showColumnPicker by remember{mutableStateOf(false)}
    var visibleColumns by remember{mutableStateOf(STAT_COLUMNS.map{it.key}.toSet())}
    // Tapping a stat header cycles descending → ascending → back to the default roster order.
    var statSortKey by remember{mutableStateOf<String?>(null)}
    var statSortAscending by remember{mutableStateOf(false)}
    fun toggleStatSort(key:String){if(statSortKey!=key){statSortKey=key;statSortAscending=false} else if(!statSortAscending)statSortAscending=true else {statSortKey=null;statSortAscending=false}}
    // The orientation to return to is captured when full screen is entered, not when this screen
    // composes (the previous page's cleanup has not run yet at that point), and it is only restored
    // if full screen is still active when the screen goes away.
    var baseOrientation by remember{mutableIntStateOf(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)}
    fun toggleFullscreen(enabled:Boolean){if(enabled&&!immersive)baseOrientation=(context as? ComponentActivity)?.requestedOrientation?:ActivityInfo.SCREEN_ORIENTATION_PORTRAIT;immersive=enabled;setStatsFullscreen(context,view,enabled,baseOrientation)}
    DisposableEffect(Unit){onDispose{if(immersive)setStatsFullscreen(context,view,false,baseOrientation)}}
    val game=remember(tick,initialGame){db.games().firstOrNull{it.id==initialGame.id}?:initialGame}
    val events=remember(tick,game.id){db.events(game.id).filterNot{it.reverted}}
    // A game shared by another account is a read-only copy: its changes would never upload.
    val viewOnly=game.ownerId!=null
    LaunchedEffect(game.id,events){db.recalculateScore(game.id);db.recalculatePlayerGameStats(game);tick++}
    Scaffold(topBar={if(!immersive)TopAppBar(title={Text(t("Game details"))},navigationIcon={BackButton(onBack)})}){pad->
        Column(Modifier.padding(pad).fillMaxSize().padding(horizontal=20.dp,vertical=8.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
            if(!immersive){
                Column(Modifier.fillMaxWidth()){
                    Text(game.title,style=MaterialTheme.typography.headlineSmall)
                    Text("${formatGameDateTime(game.scheduledAt)} · ${t(statusLabel(game.status))}",color=Orange,style=MaterialTheme.typography.bodyMedium)
                    if(viewOnly)Text(t("View Only"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
                }
                Card(Modifier.fillMaxWidth()){
                    Row(Modifier.fillMaxWidth().padding(horizontal=14.dp,vertical=8.dp),verticalAlignment=Alignment.CenterVertically){
                        TeamNameLink(game.homeName,Modifier.weight(1f),textAlign=TextAlign.Center,style=MaterialTheme.typography.titleLarge){onOpenTeam(game.homeId)}
                        Text("${game.homeScore}  :  ${game.awayScore}",Modifier.padding(horizontal=20.dp),color=Orange,style=MaterialTheme.typography.headlineMedium)
                        TeamNameLink(game.awayName,Modifier.weight(1f),textAlign=TextAlign.Center,style=MaterialTheme.typography.titleLarge){onOpenTeam(game.awayId)}
                    }
                }
                TabRow(selectedTabIndex=detailTab,containerColor=CardBlue,contentColor=Orange){
                    Tab(selected=detailTab==0,onClick={detailTab=0},text={Text(t("Statistics"))})
                    Tab(selected=detailTab==1,onClick={detailTab=1},text={Text(t("Play-by-Play"))})
                }
            }
            if(detailTab==0){
                // Both tab labels are orange, so the selected one also carries a tinted background.
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                    TabRow(selectedTabIndex=selectedTeam,modifier=Modifier.weight(1f),containerColor=CardBlue,contentColor=Orange){
                        listOf(0 to "${game.homeName} ${t("(H)")}",1 to "${game.awayName} ${t("(A)")}").forEach{(index,label)->
                            val selected=selectedTeam==index
                            Tab(
                                selected=selected,
                                onClick={selectedTeam=index},
                                modifier=Modifier.background(if(selected)Orange.copy(alpha=.16f) else Color.Transparent),
                                text={Text(label,maxLines=1,color=if(selected)Orange else SecondaryText,style=if(selected)MaterialTheme.typography.titleMedium else MaterialTheme.typography.bodyMedium)}
                            )
                        }
                    }
                    if(immersive){
                        TextButton(onClick={showColumnPicker=true}){Text(t("Select Column"),maxLines=1)}
                        TextButton(onClick={toggleFullscreen(false)}){Text("X",maxLines=1)}
                    }
                }
                if(!immersive)Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                    Text(t("Statistics"),Modifier.weight(1f),style=MaterialTheme.typography.titleSmall)
                    TextButton(onClick={showColumnPicker=true}){Text(t("Select columns"),maxLines=1)}
                    TextButton(onClick={toggleFullscreen(!immersive)}){Text(if(immersive)"X" else t("Full screen"),maxLines=1)}
                }
                StatsHeader(visibleColumns,statSortKey,statSortAscending,onSort=::toggleStatSort)
                Box(Modifier.fillMaxWidth().weight(1f)){
                    if(selectedTeam==0)TeamStats(db,game.homeId,events,game.id,fitScreen=true,visibleColumns=visibleColumns,sortKey=statSortKey,sortAscending=statSortAscending) else TeamStats(db,game.awayId,events,game.id,fitScreen=true,visibleColumns=visibleColumns,sortKey=statSortKey,sortAscending=statSortAscending)
                }
            }else{
                EventTimeline(db,game,events,Modifier.fillMaxWidth().weight(1f),onOpenTeam,editable=!viewOnly,onChanged={tick++})
            }
            // Five actions share the row, so the padding shrinks and the labels never wrap.
            if(!immersive&&viewOnly)OutlinedButton(onClick={exporting=true},modifier=Modifier.fillMaxWidth().height(48.dp)){Text(t("Export"),maxLines=1,softWrap=false)}
            if(!immersive&&!viewOnly)Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(6.dp)){
                val actionPadding=PaddingValues(horizontal=4.dp)
                Button(
                    onClick={deleting=true},
                    modifier=Modifier.weight(1f).height(48.dp),
                    colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error,contentColor=Color.White),
                    contentPadding=actionPadding
                ){Text(t("Delete"),maxLines=1,softWrap=false,style=MaterialTheme.typography.labelMedium)}
                OutlinedButton(onClick={exporting=true},modifier=Modifier.weight(1f).height(48.dp),contentPadding=actionPadding){Text(t("Export"),maxLines=1,softWrap=false,style=MaterialTheme.typography.labelMedium)}
                // A game can only be finished once; afterwards the button stays visible but inert.
                OutlinedButton(enabled=game.status!="COMPLETED",onClick={ending=true},modifier=Modifier.weight(1f).height(48.dp),contentPadding=actionPadding){Text(t("End"),maxLines=1,softWrap=false,style=MaterialTheme.typography.labelMedium)}
                Button(onClick=onScore,modifier=Modifier.weight(1f).height(48.dp),contentPadding=actionPadding){Text(t("Score"),maxLines=1,softWrap=false,style=MaterialTheme.typography.labelMedium)}
                Button(onClick=onRecord,modifier=Modifier.weight(1f).height(48.dp),contentPadding=actionPadding){Text(t("Record"),maxLines=1,softWrap=false,style=MaterialTheme.typography.labelMedium)}
            }
        }
    }
    if(showColumnPicker)StatColumnDialog(visibleColumns,{visibleColumns=it;showColumnPicker=false},{showColumnPicker=false})
    if(highlighting)HighlightsDialog(db,game){highlighting=false}
    if(exporting){
        // Export covers two different readings of the same game, so ask which one before writing a file.
        fun export(label:String,extension:String,run:()->String){
            exporting=false
            scope.launch{
                val result=withContext(Dispatchers.IO){runCatching{run()}}
                Toast.makeText(context,result.fold({t("{label} saved to Downloads/HoopReplay/{file}","label" to t(label),"file" to it)},{t("{label} export failed: {message}","label" to t(label),"message" to it.message)}),Toast.LENGTH_LONG).show()
            }
        }
        AlertDialog(
            onDismissRequest={exporting=false},
            title={Text(t("Export game"))},
            text={Column(verticalArrangement=Arrangement.spacedBy(8.dp)){
                Text(t("Choose what to export for {title}.","title" to game.title))
                Button(onClick={export("Statistics PDF","pdf"){exportStatsPdf(context,db,game)}},modifier=Modifier.fillMaxWidth()){Text(t("Statistics (PDF)"))}
                Button(onClick={export("Play-by-play PDF","pdf"){exportPlaysPdf(context,db,game)}},modifier=Modifier.fillMaxWidth()){Text(t("Play-by-Play (PDF)"))}
                OutlinedButton(onClick={export("JSON","json"){exportGameJsonFile(context,db,game)}},modifier=Modifier.fillMaxWidth()){Text(t("Game data (JSON)"))}
                Button(onClick={exporting=false;highlighting=true},modifier=Modifier.fillMaxWidth()){Text(t("Highlight Video"))}
            }},
            confirmButton={},
            dismissButton={TextButton(onClick={exporting=false}){Text(t("Cancel"))}}
        )
    }
    if(ending)AlertDialog(
        onDismissRequest={ending=false},
        title={Text(t("End game?"))},
        text={Text(t("{game} will be marked as completed. Scores and stats stay editable.","game" to game.title))},
        confirmButton={Button(onClick={db.status(game.id,"COMPLETED");ending=false;tick++}){Text(t("End"),maxLines=1,softWrap=false)}},
        dismissButton={Button(onClick={ending=false}){Text(t("Cancel"))}}
    )
    if(deleting)AlertDialog(
        onDismissRequest={deleting=false},
        title={Text(t("Delete Game?"))},
        text={Text(t("This will delete scores, stats, and recording segment records for {title}. This cannot be undone.","title" to game.title))},
        confirmButton={Button(colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error),onClick={db.deleteGame(game.id);deleting=false;onDeleted()}){Text(t("Delete"))}},
        dismissButton={Button(onClick={deleting=false}){Text(t("Cancel"))}}
    )
}

/** Where a highlight export stands inside [HighlightsDialog]. */
private sealed interface HighlightState {
    data object Picking : HighlightState
    data class Working(val label:String,val progress:Int) : HighlightState
    data class Done(val label:String,val result:HighlightResult) : HighlightState
    data class Failed(val message:String) : HighlightState
}

/**
 * Cuts a player's or a team's highlight video from this phone's recordings. Picking a target is the
 * last step, so the tap starts the export; the same frame then shows progress and the result.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable private fun HighlightsDialog(db:HoopDb,game:Game,onDismiss:()->Unit){
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    var state by remember{mutableStateOf<HighlightState>(HighlightState.Picking)}
    var job by remember{mutableStateOf<kotlinx.coroutines.Job?>(null)}
    val events=remember(game.id){db.events(game.id)}
    val segments=remember(game.id){db.segments(game.id)}
    val teams=listOf(Triple(game.awayId,game.awayName,t("(Away)")),Triple(game.homeId,game.homeName,t("(Home)")))
    // Phase 2: a finished highlight uploads at once so the Web game page can play it.
    var uploadMessage by remember{mutableStateOf<String?>(null)}
    var lastUpload by remember{mutableStateOf<(()->Unit)?>(null)}
    // Phase 3: whole recordings upload so the Web can cut any highlight later.
    var footage by remember{mutableStateOf<Pair<Int,Int>?>(null)}
    var footageProgress by remember{mutableStateOf<String?>(null)}
    val signedIn=remember{HoopSync.isSignedIn(context)}
    LaunchedEffect(game.id,signedIn){if(signedIn&&game.ownerId==null)footage=runCatching{VideoUpload.footageStatus(context,db,game.id)}.getOrNull()}
    fun uploadHighlight(result:HighlightResult,targetKey:String,label:String){
        if(!signedIn){uploadMessage=t("Sign in to share highlights on HoopReplay Web");return}
        lastUpload={uploadHighlight(result,targetKey,label)}
        uploadMessage=t("Uploading to HoopReplay Web…")
        scope.launch{uploadMessage=runCatching{VideoUpload.uploadHighlight(context,db,game.id,result,targetKey,label)}.fold({lastUpload=null;t("Uploaded to HoopReplay Web")},{t("Upload failed: {message}","message" to (it.message?:""))})}
    }
    fun uploadFootage(){
        footageProgress=t("Uploading recordings…")
        job=scope.launch{
            footageProgress=runCatching{VideoUpload.uploadFootage(context,db,game.id){sent,total->footageProgress=t("Uploading recordings… {percent}%","percent" to (if(total>0)sent*100/total else 0))}}
                .fold({null},{if(it is kotlinx.coroutines.CancellationException)throw it else t("Upload failed: {message}","message" to (it.message?:""))})
            footage=runCatching{VideoUpload.footageStatus(context,db,game.id)}.getOrNull()
        }
    }
    fun start(target:HighlightTarget,label:String,fileTag:String){
        val clips=highlightClips(events,segments,target)
        if(clips.isEmpty()){state=HighlightState.Failed(t("No plays for this selection"));return}
        val (usable,skipped)=playableClips(context,clips,segments)
        if(usable.isEmpty()){state=HighlightState.Failed(t("None of these plays were recorded on this phone"));return}
        state=HighlightState.Working(label,0)
        val name="HoopReplay_${game.id}_${fileTag}_${System.currentTimeMillis()}.mp4"
        job=scope.launch{
            state=runCatching{exportHighlight(context,usable,skipped,name){state=HighlightState.Working(label,it)}}
                .fold({uploadHighlight(it,when(target){is HighlightTarget.PlayerTarget->"player:${target.playerId}";is HighlightTarget.TeamTarget->"team:${target.teamId}"},label);HighlightState.Done(label,it)},{if(it is kotlinx.coroutines.CancellationException)throw it else HighlightState.Failed(t("Highlight export failed: {message}","message" to (it.message?:"")))})
        }
    }
    fun close(){job?.cancel();onDismiss()}
    // The screen stays on while exporting: a sleeping or backgrounded app is frozen and the export stalls.
    val view=LocalView.current
    DisposableEffect(state is HighlightState.Working){view.keepScreenOn=state is HighlightState.Working;onDispose{view.keepScreenOn=false}}
    ScreenDialog(onDismiss={close()}){
        Surface(Modifier.fillMaxSize(),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
            Column(Modifier.fillMaxSize().padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                    Text(t("Highlight Video"),Modifier.weight(1f),color=Ink,style=MaterialTheme.typography.headlineSmall)
                    TextButton(onClick={close()},modifier=Modifier.sizeIn(minWidth=48.dp,minHeight=48.dp)){Text(t("Cancel"))}
                }
                when(val current=state){
                    HighlightState.Picking->{
                        // One full-width row per team so long team names never wrap or clip.
                        teams.forEach{(teamId,name,side)->
                            Button(onClick={start(HighlightTarget.TeamTarget(teamId),"$name $side",if(teamId==game.homeId)"home" else "away")},modifier=Modifier.fillMaxWidth().height(52.dp)){Text(t("{team} Scoring","team" to "$name $side"),maxLines=1,softWrap=false,overflow=TextOverflow.Ellipsis)}
                        }
                        BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)){
                            // The chip width follows the available width so exactly 6 fit per row, like the edit-play grid.
                            val chipWidth=(maxWidth-6.dp*5)/6-1.dp
                            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)){
                                teams.forEach{(teamId,name,side)->
                                    val players=rosterOrder(db.players(teamId).filter{p->events.any{it.playerId==p.id&&!it.reverted}})
                                    if(players.isNotEmpty()){
                                        Text("$name $side",color=SecondaryText,style=MaterialTheme.typography.titleSmall)
                                        FlowRow(Modifier.fillMaxWidth(),maxItemsInEachRow=6,horizontalArrangement=Arrangement.spacedBy(6.dp),verticalArrangement=Arrangement.spacedBy(6.dp)){
                                            PlayerGridCells(players,chipWidth,6.dp){player,chipModifier->
                                                OutlinedButton(onClick={start(HighlightTarget.PlayerTarget(player.id),player.label,"p${player.id}")},modifier=chipModifier.height(46.dp),contentPadding=PaddingValues(horizontal=4.dp)){Text(playerSelectionLabel(player,players),maxLines=1,softWrap=false,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.labelMedium)}
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if(signedIn&&game.ownerId==null)Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){
                            Text(footageProgress?:footage?.let{(up,all)->t("Recordings in the cloud: {uploaded} of {total}","uploaded" to up,"total" to all)}?:t("Checking recordings…"),Modifier.weight(1f),color=SecondaryText,style=MaterialTheme.typography.bodyMedium)
                            OutlinedButton(enabled=footageProgress?.startsWith(t("Uploading recordings…"))!=true&&footage?.let{it.first<it.second}==true,onClick={uploadFootage()}){Text(t("Upload Recordings"),maxLines=1,softWrap=false)}
                        }
                    }
                    is HighlightState.Working->Column(Modifier.fillMaxWidth().weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp,Alignment.CenterVertically),horizontalAlignment=Alignment.CenterHorizontally){
                        Text(t("Creating highlight for {target}","target" to current.label),color=Ink,style=MaterialTheme.typography.titleMedium)
                        LinearProgressIndicator(progress={current.progress/100f},modifier=Modifier.fillMaxWidth(.6f))
                        Text("${current.progress}%",color=SecondaryText)
                    }
                    is HighlightState.Done->Column(Modifier.fillMaxWidth().weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp,Alignment.CenterVertically),horizontalAlignment=Alignment.CenterHorizontally){
                        Text(t("Highlight saved to Movies/HoopReplay/Highlights"),color=Ink,style=MaterialTheme.typography.titleMedium)
                        Text(t("{target} · {count} clips · {length}","target" to current.label,"count" to current.result.clips,"length" to formatClock(current.result.durationMs)),color=SecondaryText)
                        if(current.result.skipped>0)Text(t("{count} clips skipped (recording not on this phone)","count" to current.result.skipped),color=Orange)
                        uploadMessage?.let{Text(it,color=SecondaryText,textAlign=TextAlign.Center)}
                        lastUpload?.takeIf{uploadMessage?.startsWith(t("Upload failed: {message}","message" to ""))==true}?.let{retry->OutlinedButton(onClick=retry){Text(t("Retry Upload"),maxLines=1)}}
                        Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){
                            OutlinedButton(onClick={context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM,current.result.uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),null))}){Text(t("Share"),maxLines=1)}
                            Button(onClick={context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(current.result.uri,"video/mp4").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))}){Text(t("Open"),maxLines=1)}
                        }
                    }
                    is HighlightState.Failed->Column(Modifier.fillMaxWidth().weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp,Alignment.CenterVertically),horizontalAlignment=Alignment.CenterHorizontally){
                        Text(current.message,color=Ink,style=MaterialTheme.typography.titleMedium,textAlign=TextAlign.Center)
                        OutlinedButton(onClick={state=HighlightState.Picking}){Text(t("Back"),maxLines=1)}
                    }
                }
            }
        }
    }
}

private fun eventLabel(event:StatEvent):String=when(event.type){
    "STARTER"->t("Starter")
    "PTS_1","FT_MADE"->t("Free throw made")
    "PTS_2"->t("2-point field goal made")
    "PTS_3"->t("3-point field goal made")
    "MISS_2"->t("2-point field goal missed")
    "MISS_3"->t("3-point field goal missed")
    "FT_MISS"->t("Free throw missed")
    "FOULED","FOUL_DRAWN"->t("Foul drawn")
    "REB"->t("Rebound")
    "AST"->t("Assist")
    "STL"->t("Steal")
    "BLK"->t("Block")
    "TOV"->t("Turnover")
    "FOUL"->t("Foul")
    "SUB_OUT"->t("Substitution out")
    "SUB_IN"->t("Substitution in")
    "ADJ"->t("Score adjustment")
    "VIDEO"->t("Recording saved ({clock})","clock" to formatClock(event.value*1000L))
    else->event.type.replace('_',' ').lowercase().replaceFirstChar{it.titlecase()}
}



/** Short labels for the timeline, where the line must also fit the player's number and name. */
private fun eventShortLabel(event:StatEvent):String=when(event.type){
    "STARTER"->t("Starter")
    "PTS_1","FT_MADE"->t("FT made")
    "PTS_2"->t("2PT made")
    "PTS_3"->t("3PT made")
    "MISS_2"->t("2PT missed")
    "MISS_3"->t("3PT missed")
    "FT_MISS"->t("FT missed")
    "FOULED","FOUL_DRAWN"->t("Foul drawn")
    "REB"->"REB"
    "AST"->"AST"
    "STL"->"STL"
    "BLK"->"BLK"
    "TOV"->"TO"
    "FOUL"->t("Foul")
    "SUB_OUT"->t("Sub out")
    "SUB_IN"->t("Sub in")
    "ADJ"->t("Adjust")
    "VIDEO"->t("Video {clock}","clock" to formatClock(event.value*1000L))
    else->eventLabel(event)
}

/** Types that move the scoreboard: made shots, free throws, and manual +1/-1 adjustments. */
private fun isScoringType(type:String)=type.startsWith("PTS_")||type=="FT_MADE"||type=="ADJ"

private fun eventPoints(type:String,value:Int)=if(isScoringType(type))value else 0

private data class TimelineRow(val event:StatEvent,val awayScore:Int,val homeScore:Int,val scored:Boolean)

/** "Period 3" within the scheduled count, "OT 1" for overtime periods beyond it. */
private fun periodLabel(period:Int,periodCount:Int)=if(period>periodCount)t("OT {n}","n" to period-periodCount) else t("Period {n}","n" to period)

/** Compact form for the timeline and PDF: "Q3", or "OT1" past the scheduled periods. */
private fun periodShortLabel(period:Int,periodCount:Int)=if(period>periodCount)"OT${period-periodCount}" else "Q$period"

/** Filters offered above the timeline, mirroring the play-list design. */
private enum class PlayFilter(val label:String){ALL("All"),SCORING("Scoring"),FOULS("Fouls"),AWAY("Away"),HOME("Home")}

private data class TimelineHeader(val period:Int,val plays:Int,val awayScore:Int,val homeScore:Int)

/** One play, written as a single compact line the way a printed play-by-play reads. */
@Composable private fun TimelinePlayLine(event:StatEvent,player:Player?,isHome:Boolean,points:Int,onClick:(()->Unit)?=null){
    val lineModifier=if(onClick==null)Modifier.fillMaxWidth() else Modifier.fillMaxWidth().clickable(onClick=onClick)
    Row(
        lineModifier.padding(horizontal=10.dp,vertical=7.dp),
        verticalAlignment=Alignment.CenterVertically,
        horizontalArrangement=if(isHome)Arrangement.spacedBy(8.dp) else Arrangement.spacedBy(8.dp,Alignment.End)
    ){
        val badge=@Composable{
            if(points!=0)Surface(shape=CircleShape,color=if(points>0)Orange else MissRed,contentColor=Color.White){Text(if(points>0)"+$points" else "$points",Modifier.padding(horizontal=8.dp,vertical=2.dp),style=MaterialTheme.typography.labelMedium)}
        }
        val name=@Composable{
            // A manual adjustment belongs to the team, so no "Unassigned" placeholder for it.
            // The name gives way (with an ellipsis) so the action text always stays complete —
            // "2PT missed" clipped to "2PT" used to read as a made basket.
            if(event.type!="ADJ")Text(player?.let{it.label}?:t("Unassigned"),Modifier.weight(1f,fill=false),style=MaterialTheme.typography.titleSmall,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
        }
        val label=@Composable{
            Text(eventShortLabel(event),color=SecondaryText,style=MaterialTheme.typography.bodyMedium,maxLines=1,textAlign=if(isHome)TextAlign.Start else TextAlign.End)
        }
        // Home plays read left to right from the middle; away plays are mirrored so both hug the clock.
        if(isHome){badge();name();label()}else{label();name();badge()}
    }
}

@Composable private fun EventTimeline(db:HoopDb,game:Game,events:List<StatEvent>,modifier:Modifier=Modifier,onOpenTeam:(String)->Unit={},editable:Boolean=false,autoScrollToLatest:Boolean=false,showTeamHeader:Boolean=true,filter:PlayFilter=PlayFilter.ALL,onChanged:()->Unit={}){
    // Keyed on events too: a play can be reassigned to a player created from the edit panel, and a
    // roster cached only per game would still render that play as unassigned.
    val players=remember(game.id,events){(db.players(game.homeId)+db.players(game.awayId)).associateBy{it.id}}
    var editing by remember{mutableStateOf<StatEvent?>(null)}
    var collapsed by remember{mutableStateOf(setOf<Int>())}
    val ordered=remember(events){events.sortedWith(compareBy<StatEvent>{it.period}.thenByDescending{it.gameClockMs}.thenBy{it.id})}
    val rows=remember(ordered,game.homeId,game.awayId){
        var awayScore=0
        var homeScore=0
        ordered.map{event->
            val scored=isScoringType(event.type)
            if(scored&&event.teamId==game.awayId)awayScore+=event.value
            if(scored&&event.teamId==game.homeId)homeScore+=event.value
            TimelineRow(event,awayScore,homeScore,scored)
        }
    }
    // Filtering keeps the running score computed above, so a filtered list still shows the real score.
    val visible=remember(rows,filter,game.homeId,game.awayId){
        rows.filter{row->when(filter){
            PlayFilter.ALL->true
            PlayFilter.SCORING->row.scored
            PlayFilter.FOULS->row.event.type=="FOUL"||row.event.type=="FOULED"||row.event.type.startsWith("FT_")
            PlayFilter.AWAY->row.event.teamId==game.awayId
            PlayFilter.HOME->row.event.teamId==game.homeId
        }}
    }
    if(ordered.isEmpty()){
        Box(modifier,contentAlignment=Alignment.Center){Text(t("No play-by-play events yet"),color=Color.Gray)}
        return
    }
    Box(modifier){
        Column(Modifier.fillMaxSize().background(Color.White)){
        // The live scoring screen already names both sides in its top bar, so the timeline there
        // repeats nothing.
        if(showTeamHeader)Row(Modifier.fillMaxWidth().padding(horizontal=8.dp,vertical=4.dp),verticalAlignment=Alignment.CenterVertically){
            TeamNameLink(t("{team} (Away)","team" to game.awayName),Modifier.weight(1f),textAlign=TextAlign.Center,style=MaterialTheme.typography.titleSmall,maxLines=1){onOpenTeam(game.awayId)}
            Text(t("Time"),Modifier.width(82.dp),color=Orange,textAlign=TextAlign.Center,style=MaterialTheme.typography.labelSmall)
            TeamNameLink(t("{team} (Home)","team" to game.homeName),Modifier.weight(1f),textAlign=TextAlign.Center,style=MaterialTheme.typography.titleSmall,maxLines=1){onOpenTeam(game.homeId)}
        }
        val listState=rememberLazyListState()
        // Keep the newest play visible while scoring: the timeline is oldest-first, so a new play
        // lands at the bottom and would otherwise stay off screen.
        if(autoScrollToLatest)LaunchedEffect(visible.size){if(visible.isNotEmpty())listState.animateScrollToItem(visible.lastIndex)}
        // Plays are grouped by period, each group headed by its play count and closing score.
        val grouped=remember(visible){visible.groupBy{it.event.period}.toSortedMap()}
        LazyColumn(Modifier.fillMaxWidth().weight(1f),state=listState){
            grouped.forEach{(period,periodRows)->
                item(key="header-$period"){
                    val last=periodRows.last()
                    Row(Modifier.fillMaxWidth().clickable{collapsed=if(period in collapsed)collapsed-period else collapsed+period}.padding(horizontal=10.dp,vertical=8.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)){
                        Text(periodShortLabel(period,game.periodCount),color=Ink,style=MaterialTheme.typography.titleSmall)
                        Text(t("{count} plays · ends {away} - {home}","count" to periodRows.size,"away" to last.awayScore,"home" to last.homeScore),color=SecondaryText,style=MaterialTheme.typography.bodySmall,modifier=Modifier.weight(1f))
                        Text(if(period in collapsed)"${t("Expand")} ▾" else "${t("Collapse")} ▴",color=Orange,style=MaterialTheme.typography.labelMedium)
                    }
                }
                if(period !in collapsed)items(periodRows,key={it.event.id}){row->
                    val event=row.event
                    val isHome=event.teamId==game.homeId
                    val points=eventPoints(event.type,event.value)
                    Row(
                        Modifier.fillMaxWidth().background(if(row.scored)Orange.copy(alpha=.10f) else Color.Transparent),
                        verticalAlignment=Alignment.CenterVertically
                    ){
                        // A thin orange edge marks which side scored, like the design's accent bar.
                        Box(Modifier.width(3.dp).height(44.dp).background(if(row.scored&&!isHome)Orange else Color.Transparent))
                        Box(Modifier.weight(1f)){
                            if(!isHome)TimelinePlayLine(event,event.playerId?.let(players::get),false,points,if(editable)({editing=event}) else null)
                        }
                        Column(Modifier.width(82.dp),horizontalAlignment=Alignment.CenterHorizontally){
                            Text(formatClock(event.gameClockMs),color=Ink,style=MaterialTheme.typography.titleSmall)
                            if(row.scored)Text("${row.awayScore} - ${row.homeScore}",color=Orange,style=MaterialTheme.typography.labelSmall)
                        }
                        Box(Modifier.weight(1f)){
                            if(isHome)TimelinePlayLine(event,event.playerId?.let(players::get),true,points,if(editable)({editing=event}) else null)
                        }
                        Box(Modifier.width(3.dp).height(44.dp).background(if(row.scored&&isHome)Orange else Color.Transparent))
                    }
                }
            }
        }
    }
        editing?.let{event->
        // A Popup is positioned relative to the composable that opened it, so anchored to a play in
        // the middle of the timeline the panel ran off the right edge. Pin it to the window origin
        // and size it to the display so it keeps the same equal margin as ScreenDialog.
        val hostView=LocalView.current
        // The popup is placed in the host window's coordinates, and in landscape that window starts
        // beside the camera cutout. Shift back by the window's on-screen origin so the frame lines up
        // with the display and keeps the same margin on all four sides.
        val windowOrigin=IntArray(2).also{hostView.getLocationOnScreen(it)}
        val panelPosition=remember(windowOrigin[0],windowOrigin[1]){object:PopupPositionProvider{
            override fun calculatePosition(anchorBounds:IntRect,windowSize:IntSize,layoutDirection:LayoutDirection,popupContentSize:IntSize)=IntOffset(-windowOrigin[0],-windowOrigin[1])
        }}
        // Sizing this from Configuration.screenWidthDp overflowed the right edge in landscape: the
        // activity window is laid out beside the camera cutout, so it is narrower than the display
        // while the panel is pinned to the window origin. Measure the host window instead.
        val windowSize=with(LocalDensity.current){DpSize(hostView.rootView.width.toDp(),hostView.rootView.height.toDp())}
        // The insets are only meaningful in the host window, so measure the margin here and pass it in.
        val frameMargin=screenFrameMargin()
        Popup(popupPositionProvider=panelPosition,onDismissRequest={editing=null},properties=PopupProperties(focusable=true,dismissOnBackPress=true,dismissOnClickOutside=false)){
        // Without these flags the system lays the popup window out beside the camera cutout, which
        // shifts it sideways and pushes the far edge off-screen — the same fix ScreenDialog applies.
        // The system insets the popup's own window (status bar, camera cutout), so its origin is not
        // the display origin. Measure that offset once the view is attached and take it out of the
        // frame, otherwise the panel is pushed sideways and its far edge runs off-screen.
        val popupView=LocalView.current
        var windowOffset by remember{mutableStateOf(IntOffset.Zero)}
        DisposableEffect(popupView){
            popupView.post{
                val at=IntArray(2).also{popupView.getLocationOnScreen(it)}
                windowOffset=IntOffset(at[0],at[1])
            }
            onDispose{}
        }
        val density=LocalDensity.current
        val offsetX=with(density){windowOffset.x.toDp()}
        val offsetY=with(density){windowOffset.y.toDp()}
        val framePadding=PaddingValues(
            start=(frameMargin-offsetX).coerceAtLeast(0.dp),
            top=(frameMargin-offsetY).coerceAtLeast(0.dp),
            end=frameMargin,
            bottom=frameMargin
        )
        Box(Modifier.size(windowSize.width-offsetX,windowSize.height-offsetY).padding(framePadding),contentAlignment=Alignment.Center){EditPlayPanel(
            db=db,event=event,periodDurationMs=game.periodDurationMs,periodCount=game.periodCount,
            roster=db.players(event.teamId),
            onDismiss={editing=null},
            onDelete={
                db.revertEvent(event.id)
                val points=eventPoints(event.type,event.value)
                if(points!=0)db.score(game,if(event.teamId==game.homeId)-points else 0,if(event.teamId==game.awayId)-points else 0)
                editing=null
                onChanged()
            },
            onSave={playerId,period,clockMs->
                db.updateEvent(event.id,playerId,event.type,event.value,period,clockMs)
                // A substitution is one moment recorded as two adjacent events (Sub out then Sub in),
                // so moving either one drags its partner to the same period and clock.
                if(event.type=="SUB_OUT"||event.type=="SUB_IN"){
                    val all=db.events(event.gameId)
                    val idx=all.indexOfFirst{it.id==event.id}
                    val partner=(if(event.type=="SUB_OUT")all.getOrNull(idx+1)?.takeIf{it.type=="SUB_IN"} else all.getOrNull(idx-1)?.takeIf{it.type=="SUB_OUT"})
                        ?.takeIf{it.teamId==event.teamId&&!it.reverted}
                    partner?.let{db.updateEvent(it.id,it.playerId,it.type,it.value,period,clockMs)}
                }
                editing=null
                onChanged()
            }
        )}
        }
        }
    }
}

/**
 * Rendered as an overlay inside the timeline rather than as its own dialog: the timeline is also shown
 * from inside the recorder's Plays dialog, and a dialog nested inside another dialog never appears on
 * Android — tapping a play only dismissed the Plays dialog, so plays could not be edited there at all.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable private fun EditPlayPanel(db:HoopDb,event:StatEvent,periodDurationMs:Long,periodCount:Int,roster:List<Player>,onDismiss:()->Unit,onDelete:()->Unit,onSave:(String?,Int,Long)->Unit){
    var playerId by remember(event.id){mutableStateOf(event.playerId)}
    var selectedPeriod by remember(event.id){mutableIntStateOf(event.period)}
    var selectedMinute by remember(event.id){mutableIntStateOf((event.gameClockMs/60000).toInt())}
    var selectedSecond by remember(event.id){mutableIntStateOf(((event.gameClockMs/1000)%60).toInt())}
    var localRoster by remember(event.id){mutableStateOf(roster)}
    var newNumber by remember(event.id){mutableStateOf("")}
    var newFirst by remember(event.id){mutableStateOf("")}
    var newLast by remember(event.id){mutableStateOf("")}
    var activeField by remember(event.id){mutableStateOf<String?>(null)}
    var confirmDelete by remember(event.id){mutableStateOf(false)}
    Surface(Modifier.fillMaxSize(),color=PanelBlue,contentColor=Ink,shape=MaterialTheme.shapes.large,tonalElevation=8.dp){
        Column(Modifier.fillMaxSize().padding(start=14.dp,end=14.dp,top=10.dp,bottom=10.dp),verticalArrangement=Arrangement.spacedBy(6.dp)){
            // Delete/Cancel/Save live in the header so the short landscape height goes to the content.
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically){
                Text(t("Edit play"),style=MaterialTheme.typography.titleLarge)
                Text("${periodShortLabel(event.period,periodCount)}  ${formatClock(event.gameClockMs)}",Modifier.weight(1f),color=Orange,style=MaterialTheme.typography.labelLarge)
                TextButton(onClick={confirmDelete=true}){Text(t("Delete"),color=MaterialTheme.colorScheme.error)}
                TextButton(onClick=onDismiss){Text(t("Cancel"))}
                Button(onClick={onSave(playerId,selectedPeriod,selectedMinute*60000L+selectedSecond*1000L)}){Text(t("Save"))}
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)){
                // The play type shares the clock row so the short landscape height goes to the player grid.
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1.2f)){Text(eventLabel(event),style=MaterialTheme.typography.bodyLarge);Text(t("Game clock remaining"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)};val wheelMax=maxOf(periodCount,event.period);TimeWheelPicker(selectedPeriod,1,wheelMax,(1..wheelMax).map{periodLabel(it,periodCount)}.toTypedArray(),height=64.dp){selectedPeriod=it};TimeWheelPicker(selectedMinute,0,(periodDurationMs/60000L).toInt().coerceAtLeast(1),height=64.dp){selectedMinute=it};TimeWheelPicker(selectedSecond,0,59,height=64.dp){selectedSecond=it}}
                Text(t("Player"),style=MaterialTheme.typography.titleSmall)
                BoxWithConstraints(Modifier.fillMaxWidth()){
                    // The chip width follows the available width so exactly 6 fit per row.
                    val chipWidth=(maxWidth-6.dp*5)/6-1.dp
                    FlowRow(Modifier.fillMaxWidth(),maxItemsInEachRow=6,horizontalArrangement=Arrangement.spacedBy(6.dp),verticalArrangement=Arrangement.spacedBy(6.dp)){
                        // "Assign it later" leads the grid, like the "none" choice in the other pickers.
                        FilterChip(selected=playerId==null,onClick={playerId=null},modifier=Modifier.width(chipWidth).height(46.dp),label={Text(t("Assign it later"),maxLines=1)})
                        PlayerGridCells(rosterOrder(localRoster),chipWidth,6.dp){player,chipModifier->FilterChip(selected=playerId==player.id,onClick={playerId=player.id},modifier=chipModifier.height(46.dp),label={Text(if(playerId==player.id)"✓ ${playerSelectionLabel(player,localRoster)}" else playerSelectionLabel(player,localRoster),maxLines=1,softWrap=false,overflow=TextOverflow.Ellipsis)})}
                    }
                }
                Row(horizontalArrangement=Arrangement.spacedBy(6.dp),verticalAlignment=Alignment.CenterVertically){RecorderInputField(t("Number"),newNumber,activeField=="number",Modifier.weight(.35f)){activeField="number"};RecorderInputField(t("First Name"),newFirst,activeField=="first",Modifier.weight(1f)){activeField="first"};RecorderInputField(t("Last Name"),newLast,activeField=="last",Modifier.weight(1f)){activeField="last"};Button(enabled=newNumber.isNotBlank()||newFirst.isNotBlank()||newLast.isNotBlank(),onClick={val name=fullName(newFirst,newLast);val id=db.addPlayer(event.teamId,name,newNumber.trim());localRoster=localRoster+Player(id,event.teamId,name,newNumber.trim());playerId=id;newFirst="";newLast="";newNumber="";activeField=null}){Text(t("Add player"))}}
            }
            activeField?.let{field->
                fun apply(transform:(String)->String){when(field){"number"->newNumber=transform(newNumber).filter(Char::isDigit).take(3);"first"->newFirst=transform(newFirst).capitalizeInitial().take(24);"last"->newLast=transform(newLast).capitalizeInitial().take(24)}}
                RecorderKeyboard(numeric=field=="number",onKey={key->apply{it+key}},onBackspace={apply{it.dropLast(1)}},onClear={apply{""}},onDone={activeField=null})
            }
        }
    }
    if(confirmDelete)AlertDialog(onDismissRequest={confirmDelete=false},title={Text(t("Delete play?"))},text={Text(t("This removes the play and updates the score if it was a made shot."))},confirmButton={Button(colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error),onClick={confirmDelete=false;onDelete()}){Text(t("Delete"))}},dismissButton={Button(onClick={confirmDelete=false}){Text(t("Cancel"))}})
}

/** Groups every player into one equal-width cell in the 6-per-row grid. */
private fun playerGridSlots(players:List<Player>):List<List<Player>> {
    return players.map { listOf(it) }
}

/** Emits one grid cell per slot; [content] draws a single player button with the width it must use. */
@Composable private fun PlayerGridCells(players:List<Player>,cellWidth:Dp,gap:Dp,content:@Composable (Player,Modifier)->Unit){
    playerGridSlots(players).forEach{slot->
        content(slot[0],Modifier.width(cellWidth))
    }
}

@Composable private fun BackButton(onClick:()->Unit){
    TextButton(onClick=onClick,contentPadding=PaddingValues(start=4.dp,end=12.dp),modifier=Modifier.padding(start=4.dp)){
        Icon(Icons.AutoMirrored.Filled.ArrowBackIos,contentDescription=t("Back"),tint=Orange,modifier=Modifier.size(18.dp))
        Text(t("Back"),color=Orange,style=MaterialTheme.typography.titleMedium)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun PlayerDetailScreen(db:HoopDb,team:Team,player:Player,onBack:()->Unit,onDeleted:()->Unit){
    var current by remember{mutableStateOf(player)};var editing by remember{mutableStateOf(false)};var deleting by remember{mutableStateOf(false)};var editFirst by remember{mutableStateOf(firstNameOf(player.name))};var editLast by remember{mutableStateOf(lastNameOf(player.name))};var editNumber by remember{mutableStateOf(player.number)}
    Scaffold(topBar={TopAppBar(title={Text(current.name.ifBlank{t("Player #{number}","number" to current.number)})},navigationIcon={BackButton(onBack)})}){pad->
        Column(Modifier.padding(pad).padding(16.dp).fillMaxSize(),verticalArrangement=Arrangement.spacedBy(16.dp)){
            Card(Modifier.fillMaxWidth()){Column(Modifier.padding(24.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){Text(current.name.ifBlank{t("Player #{number}","number" to current.number)},style=MaterialTheme.typography.headlineSmall);Text(t("Jersey {number}","number" to current.number.ifBlank{t("Not set")}),color=SecondaryText);Text(team.name,color=SecondaryText)}}
            Spacer(Modifier.weight(1f))
            if(team.ownerId!=null)Text(t("View Only"),color=SecondaryText,style=MaterialTheme.typography.labelMedium)
            else Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp)){
                Button(onClick={deleting=true},modifier=Modifier.weight(1f).height(48.dp),colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error,contentColor=Color.White)){Text(t("Delete"),maxLines=1)}
                Button(onClick={editFirst=firstNameOf(current.name);editLast=lastNameOf(current.name);editNumber=current.number;editing=true},modifier=Modifier.weight(1f).height(48.dp)){Text(t("Edit"),maxLines=1)}
            }
        }
    }
    if(editing){
        AlertDialog(onDismissRequest={editing=false},title={Text(t("Edit player"))},text={Column(verticalArrangement=Arrangement.spacedBy(8.dp)){OutlinedTextField(editFirst,{editFirst=it.capitalizeInitial()},singleLine=true,label={Text(t("First name"))});OutlinedTextField(editLast,{editLast=it.capitalizeInitial()},singleLine=true,label={Text(t("Last name"))});OutlinedTextField(editNumber,{editNumber=it.filter(Char::isDigit)},singleLine=true,label={Text(t("Jersey number"))})}},confirmButton={Button(enabled=editFirst.isNotBlank()||editLast.isNotBlank()||editNumber.isNotBlank(),onClick={val name=fullName(editFirst,editLast);db.updatePlayer(current.id,name,editNumber.trim());current=Player(current.id,current.teamId,name,editNumber.trim());editing=false}){Text(t("Save"))}},dismissButton={Button(onClick={editing=false}){Text(t("Cancel"))}})
    }
    if(deleting){
        AlertDialog(onDismissRequest={deleting=false},title={Text(t("Delete Player?"))},text={Text(t("Delete {name} from {team}?","name" to current.name,"team" to team.name))},confirmButton={Button(colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error),onClick={db.deletePlayer(current.id);deleting=false;onDeleted()}){Text(t("Delete"))}},dismissButton={Button(onClick={deleting=false}){Text(t("Cancel"))}})
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Suppress("OPT_IN_USAGE")
@Composable private fun PlayerListScreen(db:HoopDb,team:Team,onBack:()->Unit,onTeamDeleted:()->Unit,onPlayer:(String)->Unit){
    var query by remember{mutableStateOf("")};var first by remember{mutableStateOf("")};var last by remember{mutableStateOf("")};var number by remember{mutableStateOf("")};var showAdd by remember{mutableStateOf(false)};var deleting by remember{mutableStateOf<Player?>(null)};var deletingTeam by remember{mutableStateOf(false)};var message by remember{mutableStateOf<String?>(null)};var tick by remember{mutableIntStateOf(0)}
    val players=remember(tick){db.players(team.id)};val shown=remember(players,query){val q=query.trim();rosterOrder(players.filter{it.name.contains(q,true)||it.number.contains(q,true)})}
    Scaffold(topBar={TopAppBar(title={Text(team.name)},navigationIcon={BackButton(onBack)},actions={
        if(team.ownerId!=null)Text(t("View Only"),color=SecondaryText,style=MaterialTheme.typography.labelMedium,modifier=Modifier.padding(end=16.dp))
        else Row(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically,modifier=Modifier.padding(end=12.dp)){
            Button(onClick={deletingTeam=true},contentPadding=PaddingValues(horizontal=12.dp,vertical=6.dp),colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error,contentColor=Color.White)){Text(t("Delete team"),maxLines=1)}
            Button(onClick={showAdd=true},contentPadding=PaddingValues(horizontal=16.dp,vertical=6.dp),colors=ButtonDefaults.buttonColors(containerColor=Orange,contentColor=Color.White)){Text(t("Add player"),maxLines=1)}
        }
    })}){pad->Column(Modifier.padding(pad).padding(horizontal=16.dp).fillMaxSize()){
        OutlinedTextField(query,{query=it},Modifier.fillMaxWidth(),singleLine=true,label={Text(t("Search players…"))},placeholder={Text(t("Enter a name or number"))})
        message?.let{Text(it,color=MaterialTheme.colorScheme.error,modifier=Modifier.padding(top=8.dp))}
        if(shown.isEmpty())Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.Center){Text(if(query.isBlank())t("No players yet.") else t("No players found"),color=Color.Gray)}
        else LazyColumn(Modifier.padding(top=12.dp).weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)){items(shown,key={it.id}){player->Card(Modifier.fillMaxWidth().clickable{onPlayer(player.id)}){Row(Modifier.fillMaxWidth().padding(16.dp),verticalAlignment=Alignment.CenterVertically){Box(Modifier.size(44.dp).background(Orange),contentAlignment=Alignment.Center){Text(player.number.ifBlank{"--"},color=Color.White)};Column(Modifier.padding(start=14.dp).weight(1f)){Text(player.name.ifBlank{t("Player #{number}","number" to player.number)},style=MaterialTheme.typography.titleMedium);Text(t("Jersey {number}","number" to player.number.ifBlank{t("Not set")}),color=Color.Gray)}}}}}
    }}
    if(showAdd)AlertDialog(onDismissRequest={showAdd=false},title={Text(t("Add player"))},text={Column(verticalArrangement=Arrangement.spacedBy(8.dp)){Text(t("Name or jersey number is required"),color=Color.Gray);OutlinedTextField(first,{first=it.capitalizeInitial()},singleLine=true,label={Text(t("First name"))});OutlinedTextField(last,{last=it.capitalizeInitial()},singleLine=true,label={Text(t("Last name"))});OutlinedTextField(number,{number=it.filter(Char::isDigit)},singleLine=true,label={Text(t("Jersey number"))})}},confirmButton={Button(enabled=first.isNotBlank()||last.isNotBlank()||number.isNotBlank(),onClick={db.addPlayer(team.id,fullName(first,last),number.trim());first="";last="";number="";showAdd=false;tick++}){Text(t("Save"))}},dismissButton={Button(onClick={showAdd=false}){Text(t("Cancel"))}})
    if(deletingTeam)AlertDialog(onDismissRequest={deletingTeam=false},title={Text(t("Delete team?"))},text={Text(t("This will delete {name} and all of its players. Teams used in games cannot be deleted.","name" to team.name))},confirmButton={Button(colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error),onClick={deletingTeam=false;if(db.deleteTeam(team.id))onTeamDeleted() else message=t("This team is used in a game and cannot be deleted")}){Text(t("Delete"))}},dismissButton={Button(onClick={deletingTeam=false}){Text(t("Cancel"))}})
    deleting?.let{player->AlertDialog(onDismissRequest={deleting=null},title={Text(t("Delete Player?"))},text={Text(t("Delete #{number} {name} from {team}? Historical data will be retained but no longer linked to the player.","number" to player.number,"name" to player.name,"team" to team.name))},confirmButton={Button(colors=ButtonDefaults.buttonColors(containerColor=MaterialTheme.colorScheme.error),onClick={db.deletePlayer(player.id);deleting=null;tick++}){Text(t("Delete"))}},dismissButton={Button(onClick={deleting=null}){Text(t("Cancel"))}})}
}

/** Stored enum values such as READY / IN_PROGRESS are shown in Title Case, never all caps. */
private fun statusLabel(status:String):String = status.lowercase().split('_').filter{it.isNotBlank()}.joinToString(" "){w->w.replaceFirstChar{it.uppercase()}}

@Composable
private fun FormTableRow(label:String,content:@Composable RowScope.()->Unit){
    Row(
        Modifier.fillMaxWidth().heightIn(min=72.dp).padding(horizontal=16.dp,vertical=8.dp),
        verticalAlignment=Alignment.CenterVertically
    ){
        Text(label,Modifier.width(96.dp),color=Color.Gray,style=MaterialTheme.typography.labelLarge,maxLines=1,softWrap=false)
        content()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TeamTableField(selected:Team?,teams:List<Team>,expanded:Boolean,onExpanded:(Boolean)->Unit,onSelected:(Team)->Unit,modifier:Modifier=Modifier){
    ExposedDropdownMenuBox(expanded=expanded,onExpandedChange=onExpanded,modifier=modifier){
        OutlinedTextField(
            value=selected?.name.orEmpty(),
            onValueChange={},
            readOnly=true,
            singleLine=true,
            placeholder={Text(t("Select a team"))},
            trailingIcon={ExposedDropdownMenuDefaults.TrailingIcon(expanded)},
            modifier=Modifier.menuAnchor(MenuAnchorType.PrimaryNotEditable).fillMaxWidth()
        )
        ExposedDropdownMenu(expanded=expanded,onDismissRequest={onExpanded(false)}){
            teams.forEach{team->
                DropdownMenuItem(
                    text={Text(team.name)},
                    onClick={onSelected(team);onExpanded(false)}
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VideoQualityField(selected:String,expanded:Boolean,onExpanded:(Boolean)->Unit,onSelected:(String)->Unit,modifier:Modifier=Modifier){
    ExposedDropdownMenuBox(expanded=expanded,onExpandedChange=onExpanded,modifier=modifier){
        OutlinedTextField(
            value=t(VideoQualityOptions.first{it.first==selected}.second),
            onValueChange={},
            readOnly=true,
            singleLine=true,
            trailingIcon={ExposedDropdownMenuDefaults.TrailingIcon(expanded)},
            modifier=Modifier.menuAnchor(MenuAnchorType.PrimaryNotEditable).fillMaxWidth()
        )
        ExposedDropdownMenu(expanded=expanded,onDismissRequest={onExpanded(false)}){
            VideoQualityOptions.forEach{(key,label)->
                DropdownMenuItem(text={Text(t(label))},onClick={onSelected(key);onExpanded(false)})
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun GameForm(db:HoopDb,onDone:()->Unit){
    val context=LocalContext.current
    val teams=remember{db.teams().filter{it.ownerId==null}.sortedBy{it.name.lowercase()}}
    var home by remember{mutableStateOf(teams.firstOrNull())}
    var away by remember{mutableStateOf(teams.firstOrNull{it.id!=home?.id})}
    var homeOpen by remember{mutableStateOf(false)}
    var awayOpen by remember{mutableStateOf(false)}
    var qualityOpen by remember{mutableStateOf(false)}
    var videoQuality by remember{mutableStateOf("HIGHEST")}
    var periodCount by remember{mutableIntStateOf(4)}
    var periodDurationMinutes by remember{mutableIntStateOf(8)}
    var scheduledAt by remember{mutableLongStateOf(System.currentTimeMillis())}
    val canSave=home!=null&&away!=null&&home?.id!=away?.id
    fun selectDate(){val calendar=Calendar.getInstance().apply{timeInMillis=scheduledAt};DatePickerDialog(context,{_,year,month,day->calendar.set(year,month,day);scheduledAt=calendar.timeInMillis},calendar.get(Calendar.YEAR),calendar.get(Calendar.MONTH),calendar.get(Calendar.DAY_OF_MONTH)).show()}
    fun selectTime(){val calendar=Calendar.getInstance().apply{timeInMillis=scheduledAt};TimePickerDialog(context,{_,hour,minute->calendar.set(Calendar.HOUR_OF_DAY,hour);calendar.set(Calendar.MINUTE,minute);calendar.set(Calendar.SECOND,0);calendar.set(Calendar.MILLISECOND,0);scheduledAt=calendar.timeInMillis},calendar.get(Calendar.HOUR_OF_DAY),calendar.get(Calendar.MINUTE),false).show()}
    Scaffold(
        topBar={TopAppBar(title={Text(t("Create Game"))},navigationIcon={BackButton(onDone)})}
    ){pad->
        LazyColumn(
            Modifier.padding(pad).fillMaxSize().padding(horizontal=20.dp),
            contentPadding=PaddingValues(top=20.dp,bottom=32.dp),
            verticalArrangement=Arrangement.spacedBy(20.dp)
        ){
            item{
                Column(verticalArrangement=Arrangement.spacedBy(4.dp)){
                    Text(t("New Game"),style=MaterialTheme.typography.headlineMedium)
                    Text(t("Set up the game and choose the teams"),color=Color.Gray)
                }
            }
            item{
                Card(Modifier.fillMaxWidth()){
                    Column{
                        FormTableRow(t("Date")){
                            OutlinedButton(onClick={selectDate()},modifier=Modifier.weight(1f)){
                                Text(SimpleDateFormat("MMM d, yyyy",Locale.getDefault()).format(scheduledAt))
                            }
                        }
                        HorizontalDivider()
                        FormTableRow(t("Time")){
                            OutlinedButton(onClick={selectTime()},modifier=Modifier.weight(1f)){
                                Text(SimpleDateFormat("h:mm a",Locale.getDefault()).format(scheduledAt))
                            }
                        }
                        HorizontalDivider()
                        FormTableRow(t("Home")){
                            TeamTableField(home,teams,homeOpen,{homeOpen=it},{picked->if(picked.id==away?.id)away=home;home=picked},Modifier.weight(1f))
                        }
                        HorizontalDivider()
                        FormTableRow(t("Away")){
                            TeamTableField(away,teams,awayOpen,{awayOpen=it},{picked->if(picked.id==home?.id)home=away;away=picked},Modifier.weight(1f))
                        }
                        HorizontalDivider()
                        FormTableRow(t("Periods")){
                            OutlinedButton(onClick={periodCount=(periodCount-1).coerceAtLeast(1)},enabled=periodCount>1){Text("−")}
                            Text("$periodCount",Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.titleMedium)
                            OutlinedButton(onClick={periodCount=(periodCount+1).coerceAtMost(20)},enabled=periodCount<20){Text("+")}
                        }
                        HorizontalDivider()
                        FormTableRow(t("Per period")){
                            OutlinedButton(onClick={periodDurationMinutes=(periodDurationMinutes-1).coerceAtLeast(1)},enabled=periodDurationMinutes>1){Text("−")}
                            Text(t("{n} min","n" to periodDurationMinutes),Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.titleMedium)
                            OutlinedButton(onClick={periodDurationMinutes=(periodDurationMinutes+1).coerceAtMost(60)},enabled=periodDurationMinutes<60){Text("+")}
                        }
                        HorizontalDivider()
                        FormTableRow(t("Resolution")){
                            VideoQualityField(videoQuality,qualityOpen,{qualityOpen=it},{videoQuality=it},Modifier.weight(1f))
                        }
                    }
                }
            }
            item{
                Card(colors=CardDefaults.cardColors(containerColor=CardBlue),modifier=Modifier.fillMaxWidth()){
                    Row(
                        Modifier.fillMaxWidth().padding(20.dp),
                        horizontalArrangement=Arrangement.SpaceBetween,
                        verticalAlignment=Alignment.CenterVertically
                    ){
                        Text(home?.name?:t("Home"),Modifier.weight(1f),style=MaterialTheme.typography.titleLarge)
                        Text(t("VS"),Modifier.padding(horizontal=16.dp),color=Orange,style=MaterialTheme.typography.titleMedium)
                        Text(away?.name?:t("Away"),Modifier.weight(1f),style=MaterialTheme.typography.titleLarge)
                    }
                }
            }
            item{
                Button(
                    enabled=canSave,
                    onClick={db.addGame("${home!!.name} vs ${away!!.name}",home!!.id,away!!.id,scheduledAt,videoQuality,periodCount,periodDurationMinutes*60_000L);onDone()},
                    modifier=Modifier.fillMaxWidth().height(56.dp)
                ){Text(t("Create Game"))}
            }
        }
    }
}

/**
 * Recording-mode state machine from docs/record_button_workflow_v3.md. Two button positions and
 * three user-visible states: IDLE (Start/Exit), RECORDING (Pause/Stop), PAUSED (Resume/Stop).
 * Pause and Resume act on the same recording session and file; Stop finalizes automatically and
 * every finished file becomes one recording entry in Plays. STARTING/STOPPING/ERROR are internal
 * transient states used for debouncing and recovery. The game clock runs while recording.
 */
private enum class RecorderState{IDLE,STARTING,RECORDING,PAUSED,STOPPING,ERROR}

private const val MIN_RECORDING_BYTES=500L*1024*1024

private val videoFileNameFormatter=DateTimeFormatter.ofPattern("yyyyMMdd_HHmmssSSS").withZone(ZoneId.systemDefault())
private fun videoFileName():String="HoopReplay_${videoFileNameFormatter.format(Instant.now())}.mp4"

private fun lowStorage(context:Context):Boolean=try{
    val dir=context.getExternalFilesDir(null)
    dir!=null&&StatFs(dir.path).availableBytes<MIN_RECORDING_BYTES
}catch(e:Exception){false}

/**
 * A crash while recording leaves the MediaStore row pending and the segment row without a uri.
 * Publishing the pending file and backfilling the segment keeps the footage instead of losing it.
 * Returns the total recovered duration in milliseconds.
 */
private fun recoverPendingRecordings(context:Context,db:HoopDb,gameId:String):Long{
    val orphans=db.orphanSegments(gameId)
    if(orphans.isEmpty())return 0L
    val resolver=context.contentResolver
    val collection=MediaStore.Video.Media.EXTERNAL_CONTENT_URI
    val projection=arrayOf(MediaStore.Video.Media._ID,MediaStore.Video.Media.DISPLAY_NAME,MediaStore.Video.Media.IS_PENDING)
    val selection="${MediaStore.Video.Media.DISPLAY_NAME} LIKE ?"
    val selectionArgs=arrayOf("HoopReplay_${gameId}_%")
    val cursor=if(Build.VERSION.SDK_INT>=Build.VERSION_CODES.R){
        val args=Bundle().apply{
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION,selection)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS,selectionArgs)
            putInt(MediaStore.QUERY_ARG_MATCH_PENDING,MediaStore.MATCH_INCLUDE)
        }
        resolver.query(collection,projection,args,null)
    }else{
        @Suppress("DEPRECATION")
        resolver.query(MediaStore.setIncludePending(collection),projection,selection,selectionArgs,null)
    }?:return 0L
    var recovered=0L
    cursor.use{c->
        while(c.moveToNext()){
            if(c.getInt(2)==0)continue
            val sequence=(c.getString(1)?:continue).removePrefix("HoopReplay_${gameId}_").substringBefore('_').toIntOrNull()?:continue
            val segmentId=orphans.firstOrNull{it.second==sequence}?.first?:continue
            val uri=ContentUris.withAppendedId(collection,c.getLong(0))
            try{
                resolver.update(uri,ContentValues().apply{put(MediaStore.Video.Media.IS_PENDING,0)},null,null)
                val retriever=MediaMetadataRetriever()
                val duration=try{
                    retriever.setDataSource(context,uri)
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?:0L
                }finally{retriever.release()}
                if(duration>0){
                    db.finalizeSegment(segmentId,uri.toString(),duration)
                    // The recovered file joins the game's Plays like any normally finished recording.
                    val game=db.games().first{it.id==gameId}
                    db.addEvent(gameId,game.homeId,null,"VIDEO",(duration/1000).toInt(),game.currentPeriod,game.clockRemainingMs,sequence,duration,duration)
                    recovered+=duration
                }
            }catch(e:Exception){}
        }
    }
    return recovered
}

private fun videoQualitySelector(value:String):QualitySelector=when(value){
    "UHD"->QualitySelector.fromOrderedList(listOf(Quality.UHD,Quality.FHD,Quality.HD,Quality.SD))
    "FHD"->QualitySelector.fromOrderedList(listOf(Quality.FHD,Quality.HD,Quality.SD))
    "HD"->QualitySelector.fromOrderedList(listOf(Quality.HD,Quality.SD))
    "SD"->QualitySelector.from(Quality.SD)
    else->QualitySelector.from(Quality.HIGHEST)
}

private class CameraSession(private val activity:ComponentActivity,private val db:HoopDb,private val gameId:String,private var videoQuality:String){var capture:VideoCapture<Recorder>?=null;var recording:Recording?=null;var sequence=0;var segmentStarted=0L;var completedMs=0L;@Volatile var recordedMs=0L;private val homeTeamId=db.games().first{it.id==gameId}.homeId;private var stopState="PAUSED";@Volatile private var overlayClockMs=0L;@Volatile private var overlayPeriod=1;@Volatile private var overlayPeriodCount=4;@Volatile private var overlayHomeName="Home";@Volatile private var overlayAwayName="Away";@Volatile private var overlayHomeScore=0;@Volatile private var overlayAwayScore=0
    private var currentSegmentId:String?=null
    private var camera:androidx.camera.core.Camera?=null
    private var previewView:PreviewView?=null
    private var zoomRatio=1f
    private val notificationManager=activity.getSystemService(NotificationManager::class.java)
    private var previousInterruptionFilter:Int?=null
    private val overlayThread=HandlerThread("HoopReplayOverlay").apply{start()}
    private val overlay=OverlayEffect(CameraEffect.VIDEO_CAPTURE,0,Handler(overlayThread.looper)){}
    init{overlay.setOnDrawListener{frame->val canvas=frame.overlayCanvas;canvas.drawColor(android.graphics.Color.TRANSPARENT,PorterDuff.Mode.CLEAR);val size=minOf(canvas.width,canvas.height).toFloat();val padding=size*.025f;val paint=Paint(Paint.ANTI_ALIAS_FLAG).apply{color=android.graphics.Color.WHITE;textSize=size*.045f;typeface=android.graphics.Typeface.DEFAULT_BOLD};val centerText="${t("Period {period}/{count}","period" to overlayPeriod,"count" to overlayPeriodCount)}  ${formatClock(overlayClockMs)}";val awayText="${overlayAwayName.take(20)}  $overlayAwayScore";val homeText="$overlayHomeScore  ${overlayHomeName.take(20)}";val baseline=padding-paint.fontMetrics.top;val bottom=baseline+paint.fontMetrics.bottom+padding;val barLeft=canvas.width*.04f;val barRight=canvas.width*.96f;val background=Paint().apply{color=android.graphics.Color.argb(140,0,0,0)};canvas.drawRoundRect(barLeft,0f,barRight,bottom,padding,padding,background);paint.textAlign=Paint.Align.LEFT;canvas.drawText(awayText,barLeft+padding,baseline,paint);paint.textAlign=Paint.Align.CENTER;canvas.drawText(centerText,canvas.width/2f,baseline,paint);paint.textAlign=Paint.Align.RIGHT;canvas.drawText(homeText,barRight-padding,baseline,paint);true}}
    fun updateClock(period:Int,periodCount:Int,clockMs:Long){overlayPeriod=period;overlayPeriodCount=periodCount;overlayClockMs=clockMs}
    fun updateScoreboard(homeName:String,homeScore:Int,awayName:String,awayScore:Int){overlayHomeName=homeName;overlayHomeScore=homeScore;overlayAwayName=awayName;overlayAwayScore=awayScore}
    fun bind(view:PreviewView){
        previewView=view
        val scaleDetector=ScaleGestureDetector(view.context,object:ScaleGestureDetector.SimpleOnScaleGestureListener(){
            override fun onScaleBegin(detector:ScaleGestureDetector):Boolean{zoomRatio=camera?.cameraInfo?.zoomState?.value?.zoomRatio?:zoomRatio;return true}
            override fun onScale(detector:ScaleGestureDetector):Boolean{
                val zoomState=camera?.cameraInfo?.zoomState?.value?:return false
                zoomRatio=(zoomRatio*detector.scaleFactor).coerceIn(zoomState.minZoomRatio,zoomState.maxZoomRatio)
                camera?.cameraControl?.setZoomRatio(zoomRatio)
                return true
            }
        })
        view.setOnTouchListener{_,event->scaleDetector.onTouchEvent(event);true}
        view.addOnLayoutChangeListener{changedView,_,_,_,_,_,_,_,_->
            val rotation=changedView.display?.rotation?:Surface.ROTATION_90
            capture?.targetRotation=rotation
        }
        view.post{bindUseCases(view)}
    }
    private var cameraProvider:ProcessCameraProvider?=null
    /** Called on the main thread once the capture use case is bound and recording can start. */
    var onCameraReady:(()->Unit)?=null
    private fun bindUseCases(view:PreviewView){
        val future=ProcessCameraProvider.getInstance(activity)
        future.addListener({
            val provider=future.get()
            cameraProvider=provider
            val rotation=view.display?.rotation?:Surface.ROTATION_90
            val preview=androidx.camera.core.Preview.Builder().setTargetRotation(rotation).build().also{it.surfaceProvider=view.surfaceProvider}
            capture=VideoCapture.withOutput(Recorder.Builder().setQualitySelector(videoQualitySelector(videoQuality)).build()).also{it.targetRotation=rotation}
            provider.unbindAll()
            val group=UseCaseGroup.Builder().addUseCase(preview).addUseCase(capture!!).addEffect(overlay).build()
            camera=provider.bindToLifecycle(activity,CameraSelector.DEFAULT_BACK_CAMERA,group)
            onCameraReady?.invoke()
        },ContextCompat.getMainExecutor(activity))
    }
    fun setVideoQuality(value:String){if(recording==null&&value!=videoQuality){videoQuality=value;previewView?.let(::bindUseCases)}}
    fun canSilenceNotifications()=notificationManager.isNotificationPolicyAccessGranted
    private fun silenceNotifications(){if(canSilenceNotifications()&&previousInterruptionFilter==null){previousInterruptionFilter=notificationManager.currentInterruptionFilter;notificationManager.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_NONE)}}
    private fun restoreNotifications(){previousInterruptionFilter?.let{if(canSilenceNotifications())notificationManager.setInterruptionFilter(it)};previousInterruptionFilter=null}
    fun start(audio:Boolean,onEvent:(String)->Unit):Boolean{if(recording!=null)return true;val cap=capture?:return false;silenceNotifications();stopState="PAUSED";recordedMs=0;val values=ContentValues().apply{put(MediaStore.Video.Media.DISPLAY_NAME,videoFileName());put(MediaStore.Video.Media.MIME_TYPE,"video/mp4");put(MediaStore.Video.Media.RELATIVE_PATH,"Movies/HoopReplay")};val options=MediaStoreOutputOptions.Builder(activity.contentResolver,MediaStore.Video.Media.EXTERNAL_CONTENT_URI).setContentValues(values).build();var pending:PendingRecording=cap.output.prepareRecording(activity,options);if(audio&&ContextCompat.checkSelfPermission(activity,Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)pending=pending.withAudioEnabled();sequence++;segmentStarted=SystemClock.elapsedRealtime();recording=pending.start(ContextCompat.getMainExecutor(activity)){event->when(event){is VideoRecordEvent.Start->{currentSegmentId=db.startSegment(gameId,sequence);onEvent("RECORDING")};is VideoRecordEvent.Status->{recordedMs=event.recordingStats.recordedDurationNanos/1_000_000};is VideoRecordEvent.Finalize->{val duration=event.recordingStats.recordedDurationNanos/1_000_000;completedMs+=duration;recordedMs=0;currentSegmentId?.let{db.finalizeSegment(it,event.outputResults.outputUri.toString(),duration);VideoUpload.schedule(activity,gameId)};currentSegmentId=null;restoreNotifications();if(!event.hasError()&&duration>0){
        // Each finished file is one recording entry in Plays, per the V3 workflow.
        db.addEvent(gameId,homeTeamId,null,"VIDEO",(duration/1000).toInt(),overlayPeriod,overlayClockMs,sequence,duration,duration)
    };onEvent(if(event.hasError())"ERROR" else stopState)}}};return true}
    // Pause/Resume act on the same recording session and file: paused time never enters the video.
    fun pause(){recording?.pause()}
    fun resume(){recording?.resume()}
    fun stop(finalState:String="PAUSED"){stopState=finalState;recording?.stop();recording=null;restoreNotifications()}
    /** Time actually recorded into the current file; the clock stops while paused. */
    fun segmentMs()=if(recording==null)0 else recordedMs
    fun videoMs()=completedMs+segmentMs()
    // Unbind before closing the overlay: frames must stop arriving before its handler thread dies,
    // or CameraX posts to a dead handler and the rejection surfaces on the main thread.
    fun close(){restoreNotifications();try{cameraProvider?.unbindAll()}catch(e:Exception){};overlay.close();overlayThread.quitSafely()}
}

@Composable private fun RecorderScreen(db:HoopDb,initial:Game,scoreOnly:Boolean=false,onOpenTeam:(String)->Unit,onDone:()->Unit){
    val context=LocalContext.current; val activity=context as ComponentActivity
    DisposableEffect(Unit){
        activity.requestedOrientation=ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        onDispose{activity.requestedOrientation=ActivityInfo.SCREEN_ORIENTATION_PORTRAIT}
    }
    var permission by remember{mutableStateOf(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)}
    val launcher=rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()){permission=it[Manifest.permission.CAMERA]==true}
    LaunchedEffect(Unit){if(!scoreOnly&&!permission)launcher.launch(arrayOf(Manifest.permission.CAMERA,Manifest.permission.RECORD_AUDIO))}
    // Recording cannot survive process death, so a re-opened in-progress game resumes with the
    // clock paused and the capture off; READY and COMPLETED map onto themselves.
    // The recorder always opens idle: every recording is its own session and file, and the game's
    // stored status only matters for what Stop writes back (a COMPLETED game stays COMPLETED).
    val lastPlayClock=remember(initial.id,initial.currentPeriod){db.events(initial.id).filter{it.period==initial.currentPeriod&&!it.reverted&&it.type!="STARTER"&&it.type!="VIDEO"}.lastOrNull()?.gameClockMs}
    val restoredClock=lastPlayClock?.let{minOf(initial.clockRemainingMs,it)}?:initial.clockRemainingMs
    var game by remember{mutableStateOf(initial)};var state by remember{mutableStateOf(RecorderState.IDLE)};var clockMs by remember{mutableLongStateOf(restoredClock)};var period by remember{mutableIntStateOf(initial.currentPeriod)};var tick by remember{mutableIntStateOf(0)}
    val wasCompleted=remember{initial.status=="COMPLETED"}
    // Start stays disabled until the capture use case is bound, so a tap can never be silently
    // dropped while the camera is still starting up.
    var cameraReady by remember{mutableStateOf(scoreOnly)}
    var recTick by remember{mutableIntStateOf(0)}
    var showStats by remember{mutableStateOf(false)}
    var resumeAfterStats by remember{mutableStateOf(false)}
    var showPlays by remember{mutableStateOf(false)}
    var showNotificationAccess by remember{mutableStateOf(false)}
    var pendingAction by remember{mutableStateOf<PlayerAction?>(null)}
    // The shooter is null when the user chose to assign the player later.
    var madeShot by remember{mutableStateOf<Pair<PlayerAction,Player?>?>(null)}
    var missedShot by remember{mutableStateOf<Pair<PlayerAction,Player?>?>(null)}
    var freeThrow by remember{mutableStateOf<FreeThrowFlow?>(null)}
    // A missed last free throw leaves the ball live, so the trip is only finished once the rebound
    // is assigned; the attempts are held here until then so they are written in play order.
    var freeThrowRebound by remember{mutableStateOf<Pair<FreeThrowFlow,List<Boolean>>?>(null)}
    var foul by remember{mutableStateOf<FoulFlow?>(null)}
    var substitution by remember{mutableStateOf<String?>(null)}
    var starterTeamId by remember{mutableStateOf<String?>(null)}
    // Replay the lineup events to see who is on the floor. Treating "every player with a recorded
    // stat" as the lineup never took anyone off it, so a team could show more than five players.
    fun lineupsFromEvents():Pair<Set<String>,Set<String>>{
        val recorded=db.events(game.id).filterNot{it.reverted}
        fun lineupOf(teamId:String):Set<String>{
            val roster=db.players(teamId).map{it.id}.toSet()
            val onCourt=LinkedHashSet<String>()
            recorded.filter{it.teamId==teamId}.forEach{event->
                val playerId=event.playerId
                if(playerId==null||playerId !in roster)return@forEach
                when(event.type){"STARTER","SUB_IN"->onCourt+=playerId;"SUB_OUT"->onCourt-=playerId}
            }
            return onCourt
        }
        return lineupOf(game.homeId) to lineupOf(game.awayId)
    }
    val storedLineups=remember(game.id){lineupsFromEvents()}
    var homeLineup by remember(game.id){mutableStateOf(storedLineups.first)}
    var awayLineup by remember(game.id){mutableStateOf(storedLineups.second)}
    // Undo and play edits change the lineup events behind the panel counts, so the on-court sets
    // are re-derived from the event log instead of drifting away from it.
    fun refreshLineups(){val (home,away)=lineupsFromEvents();homeLineup=home;awayLineup=away}
    var selectedQuality by remember{mutableStateOf(game.videoQuality)}
    var showClockEditor by remember{mutableStateOf(false)}
    var showLowStorage by remember{mutableStateOf(false)}
    var showStopFirst by remember{mutableStateOf(false)}
    var recoveredNoticeMs by remember{mutableStateOf<Long?>(null)}
    val scope=rememberCoroutineScope()
    var qualityOpen by remember{mutableStateOf(false)}
    var fullStats by remember{mutableStateOf(true)}
    var addPlayerTeamId by remember{mutableStateOf<String?>(null)}
    val session=remember{CameraSession(activity,db,game.id,game.videoQuality)}
    SideEffect{session.onCameraReady={cameraReady=true}}
    SideEffect{session.updateClock(period,game.periodCount,clockMs);session.updateScoreboard(game.homeName,game.homeScore,game.awayName,game.awayScore)}
    DisposableEffect(session){onDispose{session.close()}}
    // The game clock follows the recording: it runs while RECORDING and freezes with Pause. It also
    // freezes while a stat-entry dialog is open, so time spent assigning a play never drains the
    // period; the recording timer (recTick) keeps counting because the video does not stop. When
    // a period runs out it rolls into the next one (or overtime) at the configured duration.
    val statEntryOpen by rememberUpdatedState(pendingAction!=null||madeShot!=null||missedShot!=null||freeThrow!=null||freeThrowRebound!=null||foul!=null||substitution!=null||showClockEditor)
    LaunchedEffect(state){
        if(state==RecorderState.RECORDING){
            while(true){
                delay(1000)
                recTick++
                if(!statEntryOpen){
                    // Score mode is often used while re-watching a recorded game, where the real
                    // action plays back slower than live, so its game clock runs at half speed.
                    clockMs=(clockMs-(if(scoreOnly)500L else 1000L)).coerceAtLeast(0)
                    db.saveProgress(game.id,period,clockMs)
                }
            }
        }
    }
    LaunchedEffect(Unit){
        if(!scoreOnly){
            val recovered=withContext(Dispatchers.IO){recoverPendingRecordings(context,db,game.id)}
            if(recovered>0)recoveredNoticeMs=recovered
        }
    }
    fun reload(){db.recalculateScore(game.id);game=db.games().first{it.id==game.id};tick++}
    fun event(team:String,player:Player?,type:String,value:Int,points:Int=0){
        // A STARTER can only happen at the start of a period, so it is stamped with the period's
        // full clock no matter when the lineup is confirmed. A stat never creates a STARTER: a
        // player's presence on the floor comes only from recorded lineup events.
        val eventClock=if(type=="STARTER")game.periodDurationMs else clockMs
        db.addEvent(game.id,team,player?.id,type,value,period,eventClock,session.sequence,session.segmentMs(),session.videoMs())
        // Only lineup events change who is on the floor. A made shot or any other stat must never
        // silently add its player to the lineup; doing so used to turn every scorer into a starter
        // when the current five were carried into the next period.
        player?.let{
            when(type){
                "STARTER","SUB_IN"->if(team==game.homeId)homeLineup=homeLineup+it.id else if(team==game.awayId)awayLineup=awayLineup+it.id
                "SUB_OUT"->if(team==game.homeId)homeLineup=homeLineup-it.id else if(team==game.awayId)awayLineup=awayLineup-it.id
            }
        }
        if(points!=0){db.score(game,if(team==game.homeId)points else 0,if(team==game.awayId)points else 0)}
        reload()
    }
    fun undo(){db.undo(game.id)?.let{e->if(isScoringType(e.type))db.score(game,if(e.teamId==game.homeId)-e.value else 0,if(e.teamId==game.awayId)-e.value else 0);reload();refreshLineups()}}
    /**
     * Leaving is only possible while idle, so no recording ever needs stopping here. A finished
     * game keeps its COMPLETED status and a game that was never recorded stays READY.
     */
    fun leaveRecorder(){
        if(!wasCompleted&&game.status=="RECORDING")db.status(game.id,"PAUSED")
        db.saveProgress(game.id,period,clockMs)
    }
    fun leaveToTeam(teamId:String){
        if(state!=RecorderState.IDLE&&state!=RecorderState.ERROR){showStopFirst=true;return}
        leaveRecorder();onOpenTeam(teamId)
    }
    fun onRecordEvent(evt:String){
        when(evt){
            "RECORDING"->{state=RecorderState.RECORDING;if(!wasCompleted)db.status(game.id,"RECORDING")}
            "ERROR"->{state=RecorderState.ERROR}
            else->{
                // The file finalized and its Plays entry is written; the workflow returns to idle.
                state=RecorderState.IDLE
                if(!wasCompleted)db.status(game.id,"PAUSED")
                db.saveProgress(game.id,period,clockMs)
                reload()
            }
        }
    }
    /** Start creates a new unique file after the storage and Do-Not-Disturb gates. */
    fun startRecording(){
        if(state!=RecorderState.IDLE)return
        if(!session.canSilenceNotifications()){showNotificationAccess=true;return}
        if(lowStorage(context)){showLowStorage=true;return}
        state=RecorderState.STARTING
        if(!session.start(true,::onRecordEvent))state=RecorderState.IDLE
    }
    /** Stop disables everything, finalizes the file automatically, and returns to idle. */
    fun stopRecording(){
        if(state!=RecorderState.RECORDING&&state!=RecorderState.PAUSED)return
        state=RecorderState.STOPPING
        db.saveProgress(game.id,period,clockMs)
        session.stop("FINALIZED")
    }
    /** Retry re-runs pending-file recovery; success returns the workflow to idle. */
    fun retryRecovery(){
        if(state!=RecorderState.ERROR)return
        state=RecorderState.STOPPING
        scope.launch{
            withContext(Dispatchers.IO){recoverPendingRecordings(context,db,game.id)}
            state=if(db.orphanSegments(game.id).isEmpty())RecorderState.IDLE else RecorderState.ERROR
            reload()
        }
    }
    // The recorder must not be destroyed silently mid-recording: the back key is intercepted and
    // the user is told to Stop first.
    BackHandler(enabled=!scoreOnly&&state!=RecorderState.IDLE&&state!=RecorderState.ERROR){showStopFirst=true}
    if(!scoreOnly&&!permission){Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center){Column(horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(8.dp)){Text(t("Camera permission is required to record"));Button(onClick={launcher.launch(arrayOf(Manifest.permission.CAMERA,Manifest.permission.RECORD_AUDIO))}){Text(t("Grant Permission"))};Button(onClick=onDone){Text(t("Back"))}}};return}
    Box(Modifier.fillMaxSize().background(ScoreboardBackground)){
        if(!scoreOnly) AndroidView(factory={PreviewView(it).also(session::bind)},modifier=Modifier.fillMaxSize())
        TeamPanel(game.homeScore,homeLineup.size,fullStats,!scoreOnly,{starterTeamId=game.homeId},{addPlayerTeamId=game.homeId},{if(fullStats)pendingAction=PlayerAction(game.homeId,"PTS_$it",it,it,it==2||it==3) else event(game.homeId,null,"PTS_$it",it,it)},onMiss={pendingAction=PlayerAction(game.homeId,"MISS_$it",it,needsRebound=true)},onFreeThrow={freeThrow=FreeThrowFlow(game.homeId)},onFoul={foul=FoulFlow(game.homeId)},onSubstitution={substitution=game.homeId},onStat={pendingAction=PlayerAction(game.homeId,it,1)},onAdjust={delta->if(delta>0||game.homeScore>0)event(game.homeId,null,"ADJ",delta,delta)},modifier=Modifier.align(Alignment.CenterEnd).fillMaxWidth(.26f))
        TeamPanel(game.awayScore,awayLineup.size,fullStats,!scoreOnly,{starterTeamId=game.awayId},{addPlayerTeamId=game.awayId},{if(fullStats)pendingAction=PlayerAction(game.awayId,"PTS_$it",it,it,it==2||it==3) else event(game.awayId,null,"PTS_$it",it,it)},onMiss={pendingAction=PlayerAction(game.awayId,"MISS_$it",it,needsRebound=true)},onFreeThrow={freeThrow=FreeThrowFlow(game.awayId)},onFoul={foul=FoulFlow(game.awayId)},onSubstitution={substitution=game.awayId},onStat={pendingAction=PlayerAction(game.awayId,it,1)},onAdjust={delta->if(delta>0||game.awayScore>0)event(game.awayId,null,"ADJ",delta,delta)},modifier=Modifier.align(Alignment.CenterStart).fillMaxWidth(.26f))
        // Scoreboard, timeline and toolbar share one column: the timeline takes whatever height the
        // other two leave, so no strip of empty background is left over below the last play.
        Column(Modifier.align(Alignment.Center).fillMaxWidth(.48f).fillMaxHeight()){
        Row(Modifier.fillMaxWidth().background(Color(0x40000000)).padding(horizontal=10.dp,vertical=8.dp),verticalAlignment=Alignment.CenterVertically){
            TeamNameLink(t("{name} (A)","name" to game.awayName),Modifier.weight(1f),textAlign=TextAlign.Center,maxLines=1){leaveToTeam(game.awayId)}
            // softWrap off with visible overflow: when a wide digit combination makes the line a few
            // pixels too long it must not wrap (the clock landed on a clipped second line and looked
            // like it was blinking every second) — it just draws past the column edge instead.
            Column(Modifier.weight(1.35f),horizontalAlignment=Alignment.CenterHorizontally){Text("${if(period>game.periodCount)t("OT {n}","n" to period-game.periodCount) else t("Period {period}/{count}","period" to period,"count" to game.periodCount)}  ${formatClock(clockMs)}",color=Color.White,style=MaterialTheme.typography.titleLarge,maxLines=1,softWrap=false,overflow=TextOverflow.Visible);val recNowMs=recTick.let{session.recordedMs};Text(when(state){RecorderState.IDLE->t("Ready");RecorderState.STARTING->t("Starting…");RecorderState.RECORDING->if(scoreOnly)t("Running") else t("● REC {clock}","clock" to formatClock(recNowMs));RecorderState.PAUSED->if(scoreOnly)t("Paused") else t("Paused {clock}","clock" to formatClock(recNowMs));RecorderState.STOPPING->t("Stopping…");RecorderState.ERROR->t("Error")},color=if(state==RecorderState.RECORDING&&!scoreOnly)Color.Red else Orange)}
            TeamNameLink(t("{name} (H)","name" to game.homeName),Modifier.weight(1f),textAlign=TextAlign.Center,maxLines=1){leaveToTeam(game.homeId)}
        }
        // Recording mode is a viewfinder: the middle stays clear so the camera preview behind it is
        // what the user frames. The play list belongs to Score mode, which has no preview to cover.
        // While recording, the Plays button still opens the same timeline on demand.
        if(scoreOnly)EventTimeline(db,game,remember(tick){db.events(game.id).filterNot{it.reverted}},Modifier.fillMaxWidth().weight(1f).background(Color.White),editable=true,autoScrollToLatest=true,showTeamHeader=false,onChanged={reload();refreshLineups()})
        else Spacer(Modifier.fillMaxWidth().weight(1f))
        // Same backdrop as the team panels, so the grey behind Start matches the grey behind Rebound.
        Column(Modifier.fillMaxWidth().background(ScoreboardBackground).padding(8.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(6.dp)){
            // Every toolbar button shares the Rebound-style dark fill; Record and Exit keep their
            // red/orange accents on top of it.
            // Outline-only toolbar buttons: transparent fill with white labels, so the strip's
            // backdrop shows through; Record and Exit keep their red/orange accents.
            val toolbarColors=ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=Color.White,disabledContainerColor=Color.Transparent,disabledContentColor=DisabledLabel)
            // One fixed stroke for every toolbar button: the default outlined border dims when
            // disabled, and the border must never change between enabled and disabled.
            val toolbarBorder=BorderStroke(1.dp,MaterialTheme.colorScheme.outline)
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp)){
                // Position 1: Start / Pause / Resume (Retry after an error). The button never
                // vanishes — when its action is unavailable it is disabled with the border intact.
                // In score-only mode the same button drives just the game clock, with no recording.
                val pos1Label=when(state){RecorderState.IDLE->t("Start");RecorderState.STARTING->t("Starting…");RecorderState.RECORDING->t("Pause");RecorderState.PAUSED->t("Resume");RecorderState.STOPPING->t("Start");RecorderState.ERROR->t("Retry")}
                OutlinedButton(
                    enabled=when(state){RecorderState.IDLE->cameraReady;RecorderState.RECORDING,RecorderState.PAUSED,RecorderState.ERROR->true;else->false},
                    onClick={when(state){
                        RecorderState.IDLE->if(scoreOnly)state=RecorderState.RECORDING else startRecording()
                        RecorderState.RECORDING->{if(!scoreOnly)session.pause();state=RecorderState.PAUSED;db.saveProgress(game.id,period,clockMs)}
                        RecorderState.PAUSED->{if(!scoreOnly)session.resume();state=RecorderState.RECORDING}
                        RecorderState.ERROR->retryRecovery()
                        else->{}
                    }},
                    modifier=Modifier.weight(1.2f).testTag("recorder_pos1"),
                    colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=Orange,disabledContainerColor=Color.Transparent,disabledContentColor=DisabledLabel),
                    border=BorderStroke(2.dp,Orange),
                    contentPadding=PaddingValues(horizontal=8.dp)
                ){Text(pos1Label,maxLines=2,softWrap=true,textAlign=TextAlign.Center,style=MaterialTheme.typography.labelMedium)}
                // Position 2: Exit while idle, Stop while a session is running or paused — in both
                // modes. Recording mode finalizes the file; score-only mode just ends the clock
                // session and returns to idle. No Save button either way.
                val pos2Stop=state==RecorderState.RECORDING||state==RecorderState.PAUSED||state==RecorderState.STOPPING
                OutlinedButton(
                    enabled=state==RecorderState.IDLE||state==RecorderState.RECORDING||state==RecorderState.PAUSED||state==RecorderState.ERROR,
                    onClick={
                        if(state==RecorderState.RECORDING||state==RecorderState.PAUSED){
                            if(scoreOnly){state=RecorderState.IDLE;db.saveProgress(game.id,period,clockMs)} else stopRecording()
                        }
                        else{leaveRecorder();onDone()}
                    },
                    modifier=Modifier.weight(1f).testTag("recorder_pos2"),
                    colors=if(scoreOnly)ButtonDefaults.outlinedButtonColors(containerColor=ExitRed,contentColor=Color.White,disabledContainerColor=ExitRed,disabledContentColor=DisabledLabel) else ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=ExitRed,disabledContainerColor=Color.Transparent,disabledContentColor=DisabledLabel),
                    border=if(scoreOnly)null else BorderStroke(2.dp,ExitRed),
                    contentPadding=PaddingValues(horizontal=8.dp)
                ){Text(if(pos2Stop)t("Stop") else t("Exit"),maxLines=2,softWrap=true,textAlign=TextAlign.Center,style=MaterialTheme.typography.labelMedium)}
                OutlinedButton(onClick={undo()},modifier=Modifier.weight(1f),colors=toolbarColors,border=toolbarBorder,contentPadding=PaddingValues(horizontal=4.dp)){Text(t("Undo"),maxLines=2,softWrap=true,textAlign=TextAlign.Center,style=MaterialTheme.typography.labelMedium)}
                // Period and clock are edited together; always available — the game clock freezes
                // while the editor is open instead of blocking the button during recording.
                OutlinedButton(
                    onClick={showClockEditor=true},
                    modifier=Modifier.weight(1.6f),
                    colors=toolbarColors,border=toolbarBorder,
                    contentPadding=PaddingValues(horizontal=4.dp)
                ){Text(t("Period/Time"),maxLines=2,softWrap=true,textAlign=TextAlign.Center,style=MaterialTheme.typography.labelMedium)}
            }
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp)){
                OutlinedButton(onClick={fullStats=!fullStats},modifier=Modifier.weight(1.35f),colors=toolbarColors,border=toolbarBorder,contentPadding=PaddingValues(horizontal=6.dp)){Text(if(fullStats)t("Score Mode") else t("Stat Mode"),maxLines=1)}
                OutlinedButton(onClick={resumeAfterStats=state==RecorderState.RECORDING;if(resumeAfterStats&&!scoreOnly)session.pause();if(resumeAfterStats)state=RecorderState.PAUSED;showStats=true},modifier=Modifier.weight(1f),colors=toolbarColors,border=toolbarBorder,contentPadding=PaddingValues(horizontal=6.dp)){Text(t("Stats"),maxLines=1)}
                OutlinedButton(onClick={showPlays=true},modifier=Modifier.weight(1f),colors=toolbarColors,border=toolbarBorder,contentPadding=PaddingValues(horizontal=6.dp)){Text(t("Plays"),maxLines=1)}
                Box(Modifier.weight(1.45f)){
                    OutlinedButton(enabled=state==RecorderState.IDLE,onClick={qualityOpen=true},modifier=Modifier.fillMaxWidth(),colors=toolbarColors,border=toolbarBorder,contentPadding=PaddingValues(horizontal=6.dp)){Text(t("Quality: {quality}","quality" to if(selectedQuality=="HIGHEST")t("Max") else selectedQuality),maxLines=1)}
                    DropdownMenu(expanded=qualityOpen,onDismissRequest={qualityOpen=false}){VideoQualityOptions.forEach{(key,label)->DropdownMenuItem(text={Text(t(label))},onClick={selectedQuality=key;session.setVideoQuality(key);db.videoQuality(game.id,key);qualityOpen=false})}}
                }
            }
        }
        }
        addPlayerTeamId?.let { teamId ->
            RosterNumbersOverlay(
                db=db,
                teamId=teamId,
                teamName=if(teamId==game.homeId) game.homeName else game.awayName,
                onDismiss={addPlayerTeamId=null}
            )
        }
    }
    if(showStopFirst) AlertDialog(
        onDismissRequest={showStopFirst=false},
        title={Text(t("Recording in progress"))},
        text={Text(t("Stop the recording before leaving this screen."))},
        confirmButton={Button(onClick={showStopFirst=false},modifier=Modifier.testTag("stop_first_ok")){Text(t("OK"),maxLines=1,softWrap=false)}}
    )
    if(showLowStorage) AlertDialog(
        onDismissRequest={showLowStorage=false},
        title={Text(t("Not Enough Storage"))},
        text={Text(t("Recording needs at least 500 MB of free space. Free up storage and try again."))},
        confirmButton={Button(onClick={showLowStorage=false}){Text(t("OK"),maxLines=1,softWrap=false)}}
    )
    recoveredNoticeMs?.let{ms->AlertDialog(
        onDismissRequest={recoveredNoticeMs=null},
        title={Text(t("Recording Recovered"))},
        text={Text(t("An unfinished recording from this game was recovered ({clock}). It stays linked to this game.","clock" to formatClock(ms)))},
        confirmButton={Button(onClick={recoveredNoticeMs=null}){Text(t("OK"),maxLines=1,softWrap=false)}}
    )}
    if(showClockEditor) ClockEditorDialog(
        initialMs=clockMs,
        maxMs=game.periodDurationMs,
        initialPeriod=period,
        periodCount=game.periodCount,
        onDismiss={showClockEditor=false},
        onConfirm={newPeriod,newMs->
            // Correcting the clock from t1 to t2 shifts this period's plays recorded at ti <= t2 by
            // s = t2 - t1, capped at t2 (new_ti = min(ti + s, t2)): they happened while the clock
            // should have been stopped, so none may end up earlier in the game than t2. Plays with
            // ti > t2 predate the correction point and stay untouched.
            if(newPeriod==period&&newMs!=clockMs){
                val delta=newMs-clockMs
                db.events(game.id).filter{it.period==period&&!it.reverted&&it.gameClockMs<=newMs}.forEach{e->
                    db.updateEvent(e.id,e.playerId,e.type,e.value,e.period,(e.gameClockMs+delta).coerceIn(0L,newMs))
                }
                tick++
            }
            // Moving forward to a new period carries the on-court five with it: without an explicit
            // STARTER record in the new period the minutes attribution loses those players entirely.
            // The STARTER sits at the start of the new period, whatever clock the editor was set to.
            if(newPeriod>period){
                val existing=db.events(game.id).filter{!it.reverted&&it.period==newPeriod&&it.type=="STARTER"}.mapNotNull{it.playerId}.toSet()
                listOf(game.homeId to homeLineup,game.awayId to awayLineup).forEach{(teamId,lineup)->
                    lineup.take(5).filterNot(existing::contains).forEach{playerId->
                        db.addEvent(game.id,teamId,playerId,"STARTER",1,newPeriod,game.periodDurationMs,session.sequence,session.segmentMs(),session.videoMs())
                    }
                }
                tick++
            }
            period=newPeriod
            clockMs=newMs
            db.saveProgress(game.id,newPeriod,newMs)
            showClockEditor=false
        }
    )
    starterTeamId?.let{teamId->
        val current=if(teamId==game.homeId)homeLineup else awayLineup
        val players=db.players(teamId)
        StarterSelectionDialog(db,teamId,players,current.take(5).toSet(),{selected->
            // Every confirmed starter gets a STARTER record for this period — including players who
            // were already on court from earlier: the user saw them pre-selected, but only newly
            // added ones used to be written, so the period's lineup record stayed incomplete.
            val already=db.events(game.id).filter{!it.reverted&&it.teamId==teamId&&it.period==period&&it.type=="STARTER"}.mapNotNull{it.playerId}.toSet()
            selected.filterNot(already::contains).forEach{playerId->event(teamId,db.players(teamId).firstOrNull{it.id==playerId},"STARTER",1)}
            // Deselected players leave the floor, and the event log must say so.
            current.filter{it !in selected}.forEach{playerId->event(teamId,db.players(teamId).firstOrNull{it.id==playerId},"SUB_OUT",1)}
            if(teamId==game.homeId)homeLineup=selected else awayLineup=selected
            starterTeamId=null
        },{starterTeamId=null})
    }
    pendingAction?.let{action->
        val players=db.players(action.teamId)
        PlayerChoiceDialog(
                db=db,
                teamId=action.teamId,
                title=when{action.needsRebound->t("Who took this shot?");action.points>0->t("Who scored?");else->t("Who recorded this stat?")},
                context=when{action.needsRebound->t("Missed {points}-point shot","points" to action.value);action.points>0->t("Made {points}-point shot","points" to action.points);else->action.type},
                players=players,
                showNone=true,
                noneLabel=t("Assign later"),
                onPlayer={player->
                    if(action.needsRebound){missedShot=action to player;pendingAction=null}
                    else if(action.needsAssist){madeShot=action to player;pendingAction=null}
                    else{
                        event(action.teamId,player,action.type,action.value,action.points)
                        pendingAction=null
                    }
                },
                // Deferring the player keeps the rest of the flow: the rebound or assist is still asked.
                onNone={
                    if(action.needsRebound){missedShot=action to null;pendingAction=null}
                    else if(action.needsAssist){madeShot=action to null;pendingAction=null}
                    else{event(action.teamId,null,action.type,action.value,action.points);pendingAction=null}
                },
                onDismiss={pendingAction=null}
            )
    }
    madeShot?.let{(action,shooter)->
        PlayerChoiceDialog(
            db=db,
            teamId=action.teamId,
            title=t("Who made the assist?"),
            context=t("Scorer: {scorer} · {points} points","scorer" to (shooter?.let{it.label}?:t("assign later")),"points" to action.points),
            players=db.players(action.teamId).filter{it.id!=shooter?.id},
            showNone=true,
            onPlayer={player->event(action.teamId,player,"AST",1);event(action.teamId,shooter,action.type,action.value,action.points);madeShot=null},
            onNone={event(action.teamId,shooter,action.type,action.value,action.points);madeShot=null},
            // Cancel here only drops the assist question: the made shot was already confirmed.
            onDismiss={event(action.teamId,shooter,action.type,action.value,action.points);madeShot=null},
            onBack={madeShot=null;pendingAction=action}
        )
    }
    missedShot?.let{(action,shooter)->
        ReboundChoiceDialog(
            db=db,
            homeName=game.homeName,
            awayName=game.awayName,
            awayTeamId=game.awayId,
            shootingTeamId=action.teamId,
            homeTeamId=game.homeId,
            onPlayer={player->event(action.teamId,shooter,action.type,action.value);event(player.teamId,player,"REB",1);missedShot=null},
            onNone={event(action.teamId,shooter,action.type,action.value);missedShot=null},
            // Cancel here only drops the rebound question: the missed shot was already confirmed.
            onDismiss={event(action.teamId,shooter,action.type,action.value);missedShot=null}
        )
    }
    freeThrow?.let { flow ->
        if(flow.player==null&&!flow.playerSkipped) PlayerChoiceDialog(db=db,teamId=flow.teamId,title=t("Select shooter"),players=rosterOrder(db.players(flow.teamId)),showNone=true,noneLabel=t("Assign later"),
            onPlayer={player->freeThrow=flow.copy(player=player)},onNone={freeThrow=flow.copy(playerSkipped=true)},onDismiss={freeThrow=null},context=t("Select the player taking the free throws"))
        else FreeThrowDialog(
            flow=flow,
            players=db.players(flow.teamId),
            onUpdate={freeThrow=it},
            onSave={results ->
                if(results.lastOrNull()==false){freeThrowRebound=flow to results}
                else results.forEach { made -> event(flow.teamId,flow.player,if(made) "FT_MADE" else "FT_MISS",1,if(made) 1 else 0) }
                freeThrow=null
            },
            onDismiss={freeThrow=null},
            onBack={freeThrow=flow.copy(player=null,playerSkipped=false,results=emptyList())}
        )
    }
    freeThrowRebound?.let{(flow,results)->
        fun recordAttempts(){results.forEach{made->event(flow.teamId,flow.player,if(made)"FT_MADE" else "FT_MISS",1,if(made)1 else 0)}}
        ReboundChoiceDialog(
            db=db,
            homeName=game.homeName,
            awayName=game.awayName,
            awayTeamId=game.awayId,
            shootingTeamId=flow.teamId,
            homeTeamId=game.homeId,
            onPlayer={player->recordAttempts();event(player.teamId,player,"REB",1);freeThrowRebound=null},
            onNone={recordAttempts();freeThrowRebound=null},
            // Cancel here only drops the rebound question: the free throws were already recorded.
            onDismiss={recordAttempts();freeThrowRebound=null}
        )
    }
    foul?.let { flow ->
        val opponentTeamId=if(flow.teamId==game.homeId) game.awayId else game.homeId
        if(flow.player==null&&!flow.playerSkipped) PlayerChoiceDialog(db=db,teamId=flow.teamId,title=t("Who committed the foul?"),players=rosterOrder(db.players(flow.teamId)),showNone=true,noneLabel=t("Assign later"),
            onPlayer={player->foul=flow.copy(player=player)},onNone={foul=flow.copy(playerSkipped=true)},onDismiss={foul=null},context=t("Select the player who committed the foul"))
        // Picking the fouled player records the foul straight away; there is no separate confirmation step.
        // The fouled player gets the canonical FOUL_DRAWN event accepted by the cloud schema.
        else PlayerChoiceDialog(db=db,teamId=opponentTeamId,title=t("Who was fouled?"),players=rosterOrder(db.players(opponentTeamId)),showNone=true,noneLabel=t("Assign later"),
            onPlayer={player->event(flow.teamId,flow.player,"FOUL",1);event(opponentTeamId,player,"FOUL_DRAWN",1);foul=null},onNone={event(flow.teamId,flow.player,"FOUL",1);foul=null},onDismiss={foul=null},context=t("Select the opposing player who was fouled"),onBack={foul=flow.copy(player=null,playerSkipped=false)})
    }
    substitution?.let{teamId->
        val lineup=if(teamId==game.homeId)homeLineup else awayLineup
        val roster=db.players(teamId)
        // One list instead of out/in questions: the on-court five arrive selected, the user
        // reshuffles the selection freely, and Save turns the difference into sub events —
        // written as out/in pairs so each pair stays adjacent for later time edits.
        StarterSelectionDialog(db,teamId,roster,lineup,{selected->
            val outs=(lineup-selected).mapNotNull{id->roster.firstOrNull{it.id==id}}
            val ins=(selected-lineup).mapNotNull{id->roster.firstOrNull{it.id==id}}
            repeat(maxOf(outs.size,ins.size)){i->
                outs.getOrNull(i)?.let{event(teamId,it,"SUB_OUT",1)}
                ins.getOrNull(i)?.let{event(teamId,it,"SUB_IN",1)}
            }
            if(teamId==game.homeId)homeLineup=selected else awayLineup=selected
            substitution=null
        },{substitution=null},title="Substitution",hint="Tap players to change who is on the court",selectedLabel="On court",unselectedLabel="Bench",confirmLabel="Save")
    }
    if(showStats)GameStatsDialog(db,game,onDismiss={showStats=false;if(resumeAfterStats){if(!scoreOnly)session.resume();state=RecorderState.RECORDING;resumeAfterStats=false}})
    if(showPlays)PlaysDialog(db,game,remember(tick){db.events(game.id).filterNot{it.reverted}},onDismiss={showPlays=false},onChanged={reload();refreshLineups()})
    if(showNotificationAccess)AlertDialog(
        onDismissRequest={showNotificationAccess=false},
        containerColor=PanelBlue,
        title={Text(t("Silence notifications while recording"))},
        text={Text(t("Allow HoopReplay to control Do Not Disturb in system settings. Return and tap Record again. Notifications will resume when recording is paused or you exit."))},
        confirmButton={Button(onClick={showNotificationAccess=false;activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))}){Text(t("Open Settings"))}},
        dismissButton={OutlinedButton(onClick={showNotificationAccess=false}){Text(t("Cancel"))}}
    )
}

private data class PlayerAction(val teamId:String,val type:String,val value:Int,val points:Int=0,val needsAssist:Boolean=false,val needsRebound:Boolean=false)
private data class FreeThrowFlow(val teamId:String,val player:Player?=null,val playerSkipped:Boolean=false,val stage:String="PLAYER",val format:String="",val attempt:Int=1,val total:Int=2,val results:List<Boolean?> = emptyList())
private data class FoulFlow(val teamId:String,val player:Player?=null,val playerSkipped:Boolean=false)

@Composable private fun ClockEditorDialog(initialMs:Long,maxMs:Long,initialPeriod:Int,periodCount:Int,onDismiss:()->Unit,onConfirm:(Int,Long)->Unit){
    var selectedPeriod by remember { mutableIntStateOf(initialPeriod) }
    var selectedMinute by remember { mutableIntStateOf((initialMs/60000L).toInt()) }
    var selectedSecond by remember { mutableIntStateOf(((initialMs/1000L)%60L).toInt()) }
    val valueMs = (selectedMinute * 60L + selectedSecond) * 1000L
    val valid = valueMs <= maxMs
    Dialog(onDismissRequest=onDismiss){
        Surface(color=PanelBlue,shape=MaterialTheme.shapes.extraLarge){
            // Wheels-only editor: no titles or preview, just the pickers and Cancel/Save. The
            // actions sit at the top right, like every other popup.
            Column(Modifier.padding(20.dp).width(620.dp),verticalArrangement=Arrangement.spacedBy(12.dp),horizontalAlignment=Alignment.CenterHorizontally){
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically){
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick=onDismiss){Text(t("Cancel"),maxLines=1,softWrap=false)}
                    Button(enabled=valid,onClick={onConfirm(selectedPeriod,valueMs)},contentPadding=PaddingValues(horizontal=20.dp)){Text(t("Save"),maxLines=1,softWrap=false)}
                }
                // A full button-height of air between the actions and the wheels, so a flick on a
                // wheel cannot end on Cancel or Save.
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically){
                    // The wheel reaches one period past the current one, so overtime periods stay
                    // selectable after the scheduled periods run out.
                    val wheelMax=maxOf(periodCount,initialPeriod+1)
                    // Moving to another period starts it fresh, so the clock snaps to the full
                    // duration; wheeling back to the current period restores its remaining time.
                    TimeWheelPicker(selectedPeriod,1,wheelMax,(1..wheelMax).map{periodLabel(it,periodCount)}.toTypedArray()){
                        selectedPeriod=it
                        val resetMs=if(it==initialPeriod)initialMs else maxMs
                        selectedMinute=(resetMs/60000L).toInt()
                        selectedSecond=((resetMs/1000L)%60L).toInt()
                    }
                    TimeWheelPicker(selectedMinute,0,(maxMs/60000L).toInt().coerceAtLeast(1)){selectedMinute=it}
                    TimeWheelPicker(selectedSecond,0,59){selectedSecond=it}
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun FreeThrowDialog(flow:FreeThrowFlow,players:List<Player>,onUpdate:(FreeThrowFlow)->Unit,onSave:(List<Boolean>)->Unit,onDismiss:()->Unit,onBack:(()->Unit)?=null){
    // 1+1: the second shot only exists once the first one is made, so the number of shots to record
    // depends on the first result instead of being fixed like 1/2/3 free throws.
    val oneAndOne=flow.format=="1+1"
    val shots=if(oneAndOne)(if(flow.results.getOrNull(0)==true)2 else 1) else flow.total
    // The shooter is settled either by picking a player or by deferring the pick to later.
    val shooterChosen=flow.player!=null||flow.playerSkipped
    val complete=shooterChosen&&flow.results.size>=shots&&(0 until shots).all{flow.results.getOrNull(it)!=null}
    fun record(index:Int,made:Boolean){
        val next=flow.results.toMutableList()
        while(next.size<=index)next.add(null)
        next[index]=made
        // A missed first shot in a 1+1 ends the trip; drop anything recorded for the bonus shot.
        onUpdate(flow.copy(results=if(oneAndOne&&index==0&&!made)next.take(1) else next))
    }
    // The trip is over as soon as the last attempt is recorded: a made last shot saves and closes,
    // a missed one hands off to the rebound dialog, so neither needs a separate confirmation tap.
    val recorded=flow.results.take(shots).filterNotNull()
    LaunchedEffect(complete,recorded){if(complete)onSave(recorded)}
    ScreenDialog(onDismiss){
        // Wrap the content instead of filling the frame, so the Cancel/Done row stays visible.
        Surface(Modifier.fillMaxWidth().wrapContentHeight(),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
            // The Cancel/Done row is pinned below a scrollable body so it can never be pushed out of view.
            Column(Modifier.padding(20.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
            Column(Modifier.weight(1f,fill=false).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(10.dp)){
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                    Column(Modifier.weight(1f)){
                        Text(flow.player?.let{it.label}?:if(flow.playerSkipped)t("Shooter: assign later") else t("Select shooter"),color=Ink,style=MaterialTheme.typography.titleLarge)
                        if(shooterChosen)Text(if(oneAndOne)t("Shooting foul · 1+1 bonus") else t("Shooting foul · {count} free throws","count" to flow.total),color=SecondaryText)
                    }
                    onBack?.let{TextButton(onClick=it){Text(t("Previous"))}}
                    TextButton(onClick=onDismiss){Text(t("Cancel"))}
                    Button(enabled=complete,onClick={onSave(flow.results.take(shots).filterNotNull())}){Text(t("Next"))}
                }
                if(shooterChosen){
                    Text(t("Number of free throws"),color=SecondaryText)
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(6.dp)){
                        listOf("1 FT" to ("" to 1),"2 FTs" to ("" to 2),"3 FTs" to ("" to 3),"1+1" to ("1+1" to 2)).forEach{(label,value)->
                            val (format,count)=value
                            val selected=flow.format==format&&(format=="1+1"||flow.total==count)
                            Button(
                                onClick={onUpdate(flow.copy(format=format,total=count,results=emptyList()))},
                                modifier=Modifier.weight(1f),
                                colors=ButtonDefaults.buttonColors(containerColor=if(selected)Orange else Color.Gray)
                            ){Text(t(label),maxLines=1)}
                        }
                    }
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.Top){
                        (0 until shots).forEach{index->
                            val result=flow.results.getOrNull(index)
                            Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(5.dp)){
                                Text(if(oneAndOne&&index==1)t("Bonus FT") else t("FT {n}","n" to index+1),color=Ink)
                                Button(onClick={record(index,false)},modifier=Modifier.fillMaxWidth(),colors=ButtonDefaults.buttonColors(containerColor=if(result==false)MissRed else Color.Gray)){Text(t("Miss"))}
                                Button(onClick={record(index,true)},modifier=Modifier.fillMaxWidth(),colors=ButtonDefaults.buttonColors(containerColor=if(result==true)Orange else Color.Gray)){Text(t("Made +1"))}
                            }
                        }
                        repeat(maxOf(0,(if(oneAndOne)2 else 3)-shots)){Spacer(Modifier.weight(1f))}
                    }
                    if(oneAndOne&&flow.results.getOrNull(0)==false)Text(t("Missed the first shot — the 1+1 is over"),color=SecondaryText)
                    Text("${t("Points from free throws")}  ${flow.results.take(shots).count{it==true}}",color=Ink)
                }
                }
            }
        }
    }
}


@OptIn(ExperimentalLayoutApi::class)
@Composable private fun StarterSelectionDialog(db:HoopDb,teamId:String,players:List<Player>,initial:Set<String>,onConfirm:(Set<String>)->Unit,onDismiss:()->Unit,title:String="Set Starting Lineup",hint:String="Tap players to switch starters and substitutes",selectedLabel:String="Starter",unselectedLabel:String="Substitute",confirmLabel:String="Confirm"){
    var selected by remember(teamId,initial){mutableStateOf(initial)}
    var localPlayers by remember(teamId){mutableStateOf(players)}
    var otherNumber by remember{mutableStateOf("")}
    var otherFirstName by remember{mutableStateOf("")}
    var otherLastName by remember{mutableStateOf("")}
    var activeField by remember{mutableStateOf<String?>(null)}
    fun updateActive(transform:(String)->String){
        when(activeField){
            "number"->otherNumber=transform(otherNumber).filter(Char::isDigit).take(3)
            "last"->otherLastName=transform(otherLastName).capitalizeInitial().take(24)
            "first"->otherFirstName=transform(otherFirstName).capitalizeInitial().take(24)
        }
    }
    val rows=rosterOrder(localPlayers).chunked(6)
    ScreenDialog(onDismiss){
        Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center){
            Surface(Modifier.fillMaxSize(),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
                Column(Modifier.fillMaxSize().padding(horizontal=18.dp,vertical=14.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                    Column(Modifier.weight(1f)){Text(t(title),style=MaterialTheme.typography.headlineSmall);Text("${t(hint)} · ${t("{count}/5 selected","count" to selected.size)}",color=SecondaryText,style=MaterialTheme.typography.bodySmall)}
                    Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){TextButton(onClick=onDismiss){Text(t("Cancel"))};Button(onClick={onConfirm(selected)},enabled=selected.isNotEmpty()){Text(t(confirmLabel),maxLines=1,softWrap=false)}}
                }
                if(localPlayers.isEmpty())Box(Modifier.fillMaxWidth().weight(1f),contentAlignment=Alignment.Center){Text(t("This team has no players yet"),color=SecondaryText)}
                else Column(Modifier.fillMaxWidth().weight(1f,fill=false).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)){
                    rows.forEach{rowPlayers->
                        Row(Modifier.fillMaxWidth().height(52.dp),horizontalArrangement=Arrangement.spacedBy(8.dp)){
                            rowPlayers.forEach{player->
                                val isStarter=player.id in selected
                                Surface(
                                    modifier=Modifier.weight(1f).fillMaxHeight().clickable{selected=if(isStarter)selected-player.id else if(selected.size<5)selected+player.id else selected},
                                    color=if(isStarter)Color(0xFFFFE2C6) else Color(0xFFF0F1F3),
                                    contentColor=Ink,
                                    shape=MaterialTheme.shapes.medium,
                                    tonalElevation=if(isStarter)6.dp else 1.dp
                                ){
                                    Column(Modifier.fillMaxSize().padding(horizontal=12.dp,vertical=4.dp),verticalArrangement=Arrangement.Center){
                                        Text(playerSelectionLabel(player,localPlayers),maxLines=1,style=MaterialTheme.typography.titleSmall)
                                        Text(t(if(isStarter)selectedLabel else unselectedLabel),color=if(isStarter)Color(0xFF9A4600) else SecondaryText,style=MaterialTheme.typography.labelSmall)
                                    }
                                }
                            }
                            repeat(6-rowPlayers.size){Spacer(Modifier.weight(1f))}
                        }
                    }
                }
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically){
                    Text(t("New Player"),color=SecondaryText,style=MaterialTheme.typography.labelLarge)
                    RecorderInputField(t("Number"),otherNumber,activeField=="number",Modifier.weight(.55f)){activeField="number"}
                    RecorderInputField(t("First Name"),otherFirstName,activeField=="first",Modifier.weight(1f)){activeField="first"}
                    RecorderInputField(t("Last Name"),otherLastName,activeField=="last",Modifier.weight(1f)){activeField="last"}
                    Button(
                        enabled=otherNumber.isNotBlank()||otherLastName.isNotBlank()||otherFirstName.isNotBlank(),
                        onClick={
                            val name=listOf(otherFirstName.trim(),otherLastName.trim()).filter(String::isNotBlank).joinToString(" ")
                            val number=otherNumber.trim()
                            val id=db.addPlayer(teamId,name,number)
                            val player=db.players(teamId).firstOrNull{it.id==id}?:Player(id,teamId,name,number)
                            if(localPlayers.none{it.id==id})localPlayers=localPlayers+player
                            if(id !in selected&&selected.size<5)selected=selected+id
                            otherNumber=""
                            otherFirstName=""
                            otherLastName=""
                        },
                        contentPadding=PaddingValues(horizontal=14.dp)
                    ){Text(t("Add"))}
                }
                activeField?.let{
                    RecorderKeyboard(
                        numeric=it=="number",
                        onKey={key->updateActive{current->current+key}},
                        onBackspace={updateActive{current->current.dropLast(1)}},
                        onClear={updateActive{""}},
                        onDone={activeField=null}
                    )
                }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun PlayerChoiceDialog(db:HoopDb,teamId:String,title:String,players:List<Player>,showNone:Boolean,onPlayer:(Player)->Unit,onNone:()->Unit,onDismiss:()->Unit,noneLabel:String=t("No assist"),context:String?=null,highlighted:Set<String> =emptySet(),onBack:(()->Unit)?=null){
    var otherNumber by remember{mutableStateOf("")}
    var otherFirstName by remember{mutableStateOf("")}
    var otherLastName by remember{mutableStateOf("")}
    var activeField by remember{mutableStateOf<String?>(null)}
    var pickingNumber by remember{mutableStateOf(false)}
    // The caller's list is a snapshot, so roster edits made through the number pad are tracked
    // here to show up in the grid immediately after the pad closes.
    var extraPlayers by remember{mutableStateOf(listOf<Player>())}
    var removedIds by remember{mutableStateOf(setOf<String>())}
    val gridPlayers=remember(players,extraPlayers,removedIds){rosterOrder((players+extraPlayers.filter{extra->players.none{it.id==extra.id}}).filter{it.id !in removedIds})}
    fun updateActive(transform:(String)->String){
        when(activeField){
            "number"->otherNumber=transform(otherNumber).filter(Char::isDigit).take(3)
            "last"->otherLastName=transform(otherLastName).capitalizeInitial().take(24)
            "first"->otherFirstName=transform(otherFirstName).capitalizeInitial().take(24)
        }
    }
    // A dialog nested in a dialog never shows on Android, so the number pad swaps in for this
    // dialog entirely instead of opening on top of it; back returns to the player list.
    if(pickingNumber){
        ScreenDialog(onDismiss={pickingNumber=false},marginFraction=NumberPadMarginFraction){
            Surface(Modifier.fillMaxSize(),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
                NumberPickPanel(
                    db=db,
                    teamId=teamId,
                    // A number selection is the final player-selection step, so save the play
                    // immediately and close the parent dialog.
                    onAdded={picked->
                        removedIds=removedIds-picked.id
                        if(gridPlayers.none{it.id==picked.id})extraPlayers=extraPlayers+picked
                        pickingNumber=false
                        onPlayer(picked)
                    },
                    onRemoved={id->
                        removedIds=removedIds+id
                        extraPlayers=extraPlayers.filter{it.id!=id}
                    },
                    onCancel={pickingNumber=false}
                )
            }
        }
        return
    }
    ScreenDialog(onDismiss){
        Surface(Modifier.fillMaxSize(),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
            Column(Modifier.fillMaxSize().padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
                // Every header action lives on the right: Previous appears there whenever this dialog is not
                // the first step of the flow, next to Cancel. There is no Save: picking the player is the
                // last thing the user has to say, so the tap records it instead of staging it.
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1f)){Text(title,color=Ink,style=MaterialTheme.typography.headlineSmall);context?.let{Text(it,color=SecondaryText,style=MaterialTheme.typography.bodyMedium)}};Row(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically){onBack?.let{TextButton(onClick=it,modifier=Modifier.sizeIn(minWidth=48.dp,minHeight=48.dp)){Text(t("Previous"))}};TextButton(onClick=onDismiss,modifier=Modifier.sizeIn(minWidth=48.dp,minHeight=48.dp)){Text(t("Cancel"))}}}
                BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)){
                    // +1 for the trailing "Choose number" cell.
                    val rowCount=((gridPlayers.size+(if(showNone)1 else 0)+1+5)/6).coerceAtLeast(1)
                    val rowGap=if(rowCount>1)6.dp else 0.dp
                    val playerButtonHeight=52.dp
                    // Derive the width from the available space so exactly 6 buttons fit per row.
                    val playerButtonWidth=(maxWidth-12.dp*5)/6-1.dp
                    val badgeSize=32.dp
                    FlowRow(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),maxItemsInEachRow=6,horizontalArrangement=Arrangement.spacedBy(12.dp),verticalArrangement=Arrangement.spacedBy(rowGap)){
                        // The "none" choice sits in the grid so it matches the player buttons in size.
                        if(showNone)OutlinedButton(onClick=onNone,modifier=Modifier.width(playerButtonWidth).height(playerButtonHeight),colors=ButtonDefaults.outlinedButtonColors(contentColor=SecondaryText),contentPadding=PaddingValues(horizontal=8.dp,vertical=2.dp)){Text(noneLabel,maxLines=1)}
                        PlayerGridCells(gridPlayers,playerButtonWidth,12.dp){player,buttonModifier->
                            // On-court players stay highlighted; a player already picked to come out simply
                            // loses the highlight instead of disappearing from the grid.
                            val onCourt=player.id in highlighted
                            OutlinedButton(
                                onClick={onPlayer(player)},
                                modifier=buttonModifier.height(playerButtonHeight),
                                colors=if(onCourt)ButtonDefaults.outlinedButtonColors(containerColor=Orange.copy(alpha=.22f),contentColor=Ink) else ButtonDefaults.outlinedButtonColors(),
                                border=if(onCourt)BorderStroke(2.dp,Orange) else ButtonDefaults.outlinedButtonBorder,
                                contentPadding=PaddingValues(horizontal=8.dp,vertical=2.dp)
                            ){
                                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=if(player.name.isBlank())Arrangement.Center else Arrangement.spacedBy(8.dp)){Surface(Modifier.size(badgeSize),shape=CircleShape,color=Orange,contentColor=Color.White){Box(contentAlignment=Alignment.Center){Text(player.number.ifBlank{"--"},style=MaterialTheme.typography.titleMedium)}};if(player.name.isNotBlank())Text(player.name,Modifier.weight(1f),maxLines=1,style=MaterialTheme.typography.titleSmall)}
                            }
                        }
                        // The number pad is the escape hatch at the end of the list: pick a jersey
                        // number instead of a listed player.
                        OutlinedButton(onClick={pickingNumber=true},modifier=Modifier.width(playerButtonWidth).height(playerButtonHeight),colors=ButtonDefaults.outlinedButtonColors(contentColor=Orange),contentPadding=PaddingValues(horizontal=8.dp,vertical=2.dp)){Text(t("Choose number"),maxLines=1)}
                    }
                }
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically){
                    Text(t("Other Player"),color=SecondaryText,style=MaterialTheme.typography.labelLarge)
                    RecorderInputField(t("Number"),otherNumber,activeField=="number",Modifier.weight(.55f)){activeField="number"}
                    RecorderInputField(t("First Name"),otherFirstName,activeField=="first",Modifier.weight(1f)){activeField="first"}
                    RecorderInputField(t("Last Name"),otherLastName,activeField=="last",Modifier.weight(1f)){activeField="last"}
                    Button(enabled=otherNumber.isNotBlank()||otherLastName.isNotBlank()||otherFirstName.isNotBlank(),onClick={val name=listOf(otherFirstName.trim(),otherLastName.trim()).filter(String::isNotBlank).joinToString(" ");val number=otherNumber.trim();val id=db.addPlayer(teamId,name,number);onPlayer(db.players(teamId).firstOrNull{it.id==id}?:Player(id,teamId,name,number))},contentPadding=PaddingValues(horizontal=12.dp)){Text(t("Add"))}
                }
                activeField?.let{
                    RecorderKeyboard(
                        numeric=it=="number",
                        onKey={key->updateActive{current->current+key}},
                        onBackspace={updateActive{current->current.dropLast(1)}},
                        onClear={updateActive{""}},
                        onDone={activeField=null}
                    )
                }
            }
        }
    }
}

/**
 * Jersey-number pad filling 95% of the screen: nothing but the 0-99 grid, ten numbers per line.
 * The pad edits the team roster directly, so every player list of the team sees the change:
 * tapping a new number adds that player and returns to the list (where their button records the
 * play); tapping a highlighted number removes the player again and keeps the pad open for more
 * changes — unless they already have recorded stats, which keeps them and shows a toast.
 */
@Composable private fun NumberPickPanel(db:HoopDb,teamId:String,onAdded:(Player)->Unit,onRemoved:(String)->Unit,onCancel:(()->Unit)?=null){
    val context=LocalContext.current
    var version by remember{mutableIntStateOf(0)}
    val roster=remember(version){db.players(teamId)}
    val byNumber=remember(roster){roster.mapNotNull{player->player.number.trim().toIntOrNull()?.let{it to player}}.toMap()}
    Column(Modifier.fillMaxSize().padding(10.dp),verticalArrangement=Arrangement.spacedBy(4.dp)){
        onCancel?.let{cancel->Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.End){TextButton(onClick=cancel){Text(t("Cancel"))}}}
        (0..99).chunked(10).forEach{row->
            Row(Modifier.fillMaxWidth().weight(1f),horizontalArrangement=Arrangement.spacedBy(4.dp)){
                row.forEach{number->
                    val existing=byNumber[number]
                    Button(
                        onClick={
                            if(existing==null){
                                val id=db.addPlayer(teamId,"",number.toString())
                                onAdded(db.players(teamId).firstOrNull{it.id==id}?:Player(id,teamId,"",number.toString()))
                            }
                            else if(db.playerHasEvents(existing.id))Toast.makeText(context,t("#{number} already has recorded stats","number" to number),Toast.LENGTH_SHORT).show()
                            else{db.deletePlayer(existing.id);version++;onRemoved(existing.id)}
                        },
                        modifier=Modifier.weight(1f).fillMaxHeight(),
                        shape=MaterialTheme.shapes.medium,
                        contentPadding=PaddingValues(0.dp),
                        colors=ButtonDefaults.buttonColors(
                            containerColor=if(existing!=null)Orange else Color(0x22111822),
                            contentColor=if(existing!=null)Color.White else Ink
                        )
                    ){Text(number.toString(),maxLines=1,style=MaterialTheme.typography.titleMedium)}
                }
            }
        }
    }
}

/** Every popup keeps the same gap to all four screen edges; content scrolls inside that frame. */
private val DialogScreenMargin=20.dp

/** The jersey-number pad covers 95% of the screen's shorter side, margins equal on all edges. */
private const val NumberPadMarginFraction=0.025f

/**
 * One uniform gap on all four sides: the base margin, widened to clear the largest system inset
 * (status bar, camera cutout, navigation bar) so a popup never sits under system UI.
 */
@Composable private fun screenFrameMargin():Dp {
    val insets=WindowInsets.safeDrawing.asPaddingValues()
    val layoutDirection=LocalLayoutDirection.current
    return maxOf(
        DialogScreenMargin,
        insets.calculateTopPadding(),
        insets.calculateBottomPadding(),
        insets.calculateLeftPadding(layoutDirection),
        insets.calculateRightPadding(layoutDirection)
    )
}

@Composable private fun ScreenDialog(onDismiss:()->Unit,fullScreen:Boolean=false,marginFraction:Float?=null,content:@Composable ()->Unit){
    // The dialog window can be laid out larger than the display, so size the frame from the screen
    // itself instead of fillMaxSize; that keeps the same gap on all four edges.
    Dialog(onDismissRequest=onDismiss,properties=DialogProperties(usePlatformDefaultWidth=false,decorFitsSystemWindows=false)){
        // The dialog window inherits the activity's inset offsets, which pushes it off-screen in
        // landscape; force it to span the display so the frame below can centre itself.
        val dialogWindow=(LocalView.current.parent as? DialogWindowProvider)?.window
        // Once per window, not on every recomposition: reassigning window attributes relayouts the
        // window, which can recompose inset-dependent content and loop composition forever.
        DisposableEffect(dialogWindow){
            dialogWindow?.apply{
                addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
                attributes=attributes.apply{
                    width=ViewGroup.LayoutParams.MATCH_PARENT
                    height=ViewGroup.LayoutParams.MATCH_PARENT
                    gravity=Gravity.TOP or Gravity.START
                    x=0
                    y=0
                    // Without this the dialog window is laid out beside the camera cutout, which
                    // shifts it sideways and pushes the far edge off-screen.
                    if(Build.VERSION.SDK_INT>=Build.VERSION_CODES.P)layoutInDisplayCutoutMode=WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                }
            }
            onDispose{}
        }
        // Most dialogs sit in an equal frame; the stats table asks for the whole display so it can
        // show a full roster, and keeps its own inset padding instead. A margin fraction sizes the
        // frame from the screen itself (e.g. 0.025 leaves 95% of the shorter side for content)
        // while still keeping the same gap on all four edges.
        BoxWithConstraints(Modifier.fillMaxSize()){
            val margin=when{
                fullScreen->0.dp
                marginFraction!=null->minOf(maxWidth,maxHeight)*marginFraction
                else->screenFrameMargin()
            }
            Box(Modifier.fillMaxSize().padding(margin),contentAlignment=Alignment.Center){content()}
        }
    }
}

@Composable private fun RecorderInputField(label:String,value:String,selected:Boolean,modifier:Modifier=Modifier,height:Dp=54.dp,hideLabelWhenFilled:Boolean=false,onClick:()->Unit){
    Surface(
        modifier=modifier.height(height).clickable(onClick=onClick),
        color=Color.White,
        shape=RoundedCornerShape(4.dp),
        border=BorderStroke(if(selected)2.dp else 1.dp,if(selected)Orange else Color(0xFF777D86))
    ){
        Column(Modifier.fillMaxSize().padding(horizontal=8.dp,vertical=3.dp),verticalArrangement=Arrangement.Center){
            if(value.isBlank()) Text(label,color=if(selected)Orange else Color(0xFF9298A1),maxLines=1,style=MaterialTheme.typography.bodyMedium)
            else {
                // A filled field speaks for itself; the caption only crowds a compact row.
                if(!hideLabelWhenFilled)Text(label,color=if(selected)Orange else SecondaryText,style=MaterialTheme.typography.labelSmall)
                Text(value,color=Ink,maxLines=1,style=MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable private fun RowScope.TimeWheelPicker(value:Int,min:Int,max:Int,displayedValues:Array<String>?=null,height:Dp=76.dp,onValueChange:(Int)->Unit){
    Column(Modifier.width(0.dp).weight(1f),horizontalAlignment=Alignment.CenterHorizontally){
        AndroidView(factory={context->NumberPicker(context).apply{minValue=min;maxValue=max;this.displayedValues=displayedValues;wrapSelectorWheel=false;this.value=value;isFocusable=false;isFocusableInTouchMode=false;descendantFocusability=NumberPicker.FOCUS_BLOCK_DESCENDANTS;setOnValueChangedListener{_,_,new->onValueChange(new)}}},update={picker->picker.minValue=min;picker.maxValue=max;picker.displayedValues=displayedValues;picker.wrapSelectorWheel=false;picker.value=value;picker.clearFocus()},modifier=Modifier.fillMaxWidth().height(height))
    }
}

@Composable private fun RecorderKeyboard(numeric:Boolean,numericThreeByThree:Boolean=false,modifier:Modifier=Modifier.fillMaxWidth(),onKey:(String)->Unit,onBackspace:()->Unit,onClear:()->Unit,onDone:()->Unit){
    // Shift behaves like a phone keyboard: capital for the first letter of each word, lowercase after,
    // until the user pins a case with the ABC/abc key.
    var autoUppercase by remember{mutableStateOf(true)}
    var pinned by remember{mutableStateOf<Boolean?>(null)}
    val uppercase=pinned?:autoUppercase
    val rows=if(numeric)if(numericThreeByThree)listOf(listOf("1","2","3"),listOf("4","5","6"),listOf("7","8","9"),listOf("0")) else listOf(listOf("1","2","3","4","5"),listOf("6","7","8","9","0")) else listOf(
        listOf("Q","W","E","R","T","Y","U","I","O","P"),
        listOf("A","S","D","F","G","H","J","K","L"),
        listOf("Z","X","C","V","B","N","M","-","'")
    )
    Surface(modifier,color=Color(0xFFF0F1F3),shape=MaterialTheme.shapes.medium){
        Column(Modifier.padding(4.dp),verticalArrangement=Arrangement.spacedBy(2.dp)){
            rows.forEach{keys->Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(2.dp)){
                keys.forEach{key->OutlinedButton(onClick={onKey(if(uppercase)key else key.lowercase());if(pinned==null)autoUppercase=false},modifier=Modifier.weight(1f).height(if(numeric)44.dp else 30.dp),contentPadding=PaddingValues(0.dp),colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.White,contentColor=Ink)){Text(if(uppercase)key else key.lowercase(),style=if(numeric)MaterialTheme.typography.titleLarge else MaterialTheme.typography.labelSmall)}}
            }}
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(6.dp)){
                if(!numeric)OutlinedButton(onClick={onKey(" ");if(pinned==null)autoUppercase=true},modifier=Modifier.weight(2.5f).height(30.dp),colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.White,contentColor=Ink)){Text(t("Space"),style=MaterialTheme.typography.labelSmall)}
                if(!numeric)OutlinedButton(onClick={pinned=!uppercase},modifier=Modifier.weight(1f).height(30.dp),contentPadding=PaddingValues(0.dp)){Text(if(uppercase)"ABC" else "abc",style=MaterialTheme.typography.labelSmall)}
                OutlinedButton(onClick={onBackspace()},modifier=Modifier.weight(1.2f).height(if(numeric)40.dp else 30.dp),contentPadding=PaddingValues(0.dp)){Text(t("Delete"),style=if(numeric)MaterialTheme.typography.titleMedium else MaterialTheme.typography.labelSmall)}
                Button(onClick=onDone,modifier=Modifier.weight(1f).height(if(numeric)40.dp else 30.dp),contentPadding=PaddingValues(horizontal=4.dp)){Text(t("Done"),style=if(numeric)MaterialTheme.typography.titleMedium else MaterialTheme.typography.labelSmall)}
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun ReboundChoiceDialog(db:HoopDb,homeName:String,awayName:String,awayTeamId:String,shootingTeamId:String,homeTeamId:String,onPlayer:(Player)->Unit,onNone:()->Unit,onDismiss:()->Unit){
    // One team at a time behind a tab, with the new player added right here instead of in a second dialog.
    var teamId by remember{mutableStateOf(shootingTeamId)}
    var version by remember{mutableIntStateOf(0)}
    var number by remember{mutableStateOf("")}
    var firstName by remember{mutableStateOf("")}
    var lastName by remember{mutableStateOf("")}
    var activeField by remember{mutableStateOf<String?>(null)}
    var pickingNumber by remember{mutableStateOf(false)}
    val players=remember(teamId,version){rosterOrder(db.players(teamId))}
    fun updateActive(transform:(String)->String){
        when(activeField){
            "number"->number=transform(number).filter(Char::isDigit).take(3)
            "first"->firstName=transform(firstName).take(24)
            "last"->lastName=transform(lastName).take(24)
        }
    }
    // The pad takes over the whole popup. A newly selected number is the final rebounder choice,
    // so save immediately; removals keep the pad open for further roster changes.
    if(pickingNumber){
        ScreenDialog(onDismiss={pickingNumber=false},marginFraction=NumberPadMarginFraction){
            Surface(Modifier.fillMaxSize(),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
                NumberPickPanel(
                    db=db,
                    teamId=teamId,
                    onAdded={picked->version++;pickingNumber=false;onPlayer(picked)},
                    onRemoved={version++},
                    onCancel={pickingNumber=false}
                )
            }
        }
        return
    }
    ScreenDialog(onDismiss){
        Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center){
        Surface(Modifier.fillMaxSize(),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
        Column(Modifier.fillMaxSize().padding(20.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
            // Picking a player (or "No rebound") saves and closes, so the header only needs Cancel.
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                TabRow(selectedTabIndex=if(teamId==homeTeamId)0 else 1,modifier=Modifier.weight(1f),containerColor=Color.Transparent,contentColor=Orange){
                    listOf(homeTeamId to homeName,awayTeamId to awayName).forEach{(id,name)->
                        Tab(
                            selected=teamId==id,
                            onClick={teamId=id;activeField=null},
                            text={Text(if(shootingTeamId==id)t("{team} · Offensive rebound","team" to name) else t("{team} · Defensive rebound","team" to name),maxLines=1)}
                        )
                    }
                }
                TextButton(onClick=onDismiss,modifier=Modifier.sizeIn(minWidth=48.dp,minHeight=48.dp)){Text(t("Cancel"))}
            }
            Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(6.dp)){
                // The button width is derived from the available width so exactly 6 fit per row.
                BoxWithConstraints(Modifier.fillMaxWidth()){
                    val gap=6.dp
                    val buttonWidth=(maxWidth-gap*5)/6-1.dp
                    FlowRow(Modifier.fillMaxWidth(),maxItemsInEachRow=6,horizontalArrangement=Arrangement.spacedBy(gap),verticalArrangement=Arrangement.spacedBy(gap)){
                        OutlinedButton(onClick=onNone,modifier=Modifier.width(buttonWidth).height(52.dp),contentPadding=PaddingValues(horizontal=8.dp,vertical=6.dp)){Text(t("No rebound"),maxLines=1)}
                        PlayerGridCells(players,buttonWidth,gap){player,buttonModifier->OutlinedButton(onClick={onPlayer(player)},modifier=buttonModifier.height(52.dp),contentPadding=PaddingValues(horizontal=8.dp,vertical=6.dp)){Text(playerSelectionLabel(player,players),maxLines=1)}}
                        OutlinedButton(onClick={pickingNumber=true},modifier=Modifier.width(buttonWidth).height(52.dp),colors=ButtonDefaults.outlinedButtonColors(contentColor=Orange),contentPadding=PaddingValues(horizontal=8.dp,vertical=6.dp)){Text(t("Choose number"),maxLines=1)}
                    }
                }
            }
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp),verticalAlignment=Alignment.CenterVertically){
                Text(t("New Player"),color=SecondaryText,style=MaterialTheme.typography.labelLarge)
                RecorderInputField(t("Number"),number,activeField=="number",Modifier.weight(.55f)){activeField="number"}
                RecorderInputField(t("First Name"),firstName,activeField=="first",Modifier.weight(1f)){activeField="first"}
                RecorderInputField(t("Last Name"),lastName,activeField=="last",Modifier.weight(1f)){activeField="last"}
                Button(
                    enabled=number.isNotBlank()||firstName.isNotBlank()||lastName.isNotBlank(),
                    onClick={
                        db.addPlayer(teamId,fullName(firstName,lastName),number.trim())
                        number="";firstName="";lastName="";activeField=null;version++
                    },
                    contentPadding=PaddingValues(horizontal=14.dp)
                ){Text(t("Add"))}
            }
            activeField?.let{
                RecorderKeyboard(
                    numeric=it=="number",
                    onKey={key->updateActive{current->current+key}},
                    onBackspace={updateActive{current->current.dropLast(1)}},
                    onClear={updateActive{""}},
                    onDone={activeField=null}
                )
            }
        }
        }
        }
    }
}

@Composable private fun TeamPanel(score:Int,lineupCount:Int,fullStats:Boolean,transparentAccents:Boolean,onStarters:()->Unit,onAddPlayer:()->Unit,onPoints:(Int)->Unit,onMiss:(Int)->Unit,onFreeThrow:()->Unit,onFoul:()->Unit,onSubstitution:()->Unit,onStat:(String)->Unit,onAdjust:(Int)->Unit,modifier:Modifier){
    // Over the camera preview the accent buttons are outlines so the video stays visible; in Score
    // mode there is no preview behind them, so they keep their solid colour.
    val madeColors=if(transparentAccents)ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=MadeGreen) else ButtonDefaults.outlinedButtonColors(containerColor=MadeGreen,contentColor=Color.White)
    val missColors=if(transparentAccents)ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=MissRed) else ButtonDefaults.outlinedButtonColors(containerColor=MissRed,contentColor=Color.White)
    val freeThrowColors=if(transparentAccents)ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=FreeThrowOrange) else ButtonDefaults.outlinedButtonColors(containerColor=FreeThrowOrange,contentColor=Color.White)
    fun accentBorder(accent:Color)=if(transparentAccents)BorderStroke(2.dp,accent) else null
    Column(modifier.fillMaxHeight().windowInsetsPadding(WindowInsets.statusBars.only(WindowInsetsSides.Top)).background(ScoreboardBackground).padding(horizontal=7.dp,vertical=5.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(3.dp)){
        Row(horizontalArrangement=Arrangement.spacedBy(4.dp)){if(fullStats)OutlinedButton(onClick=onStarters,colors=ButtonDefaults.outlinedButtonColors(contentColor=if(lineupCount==5)Color.White else Color(0xFFFFC857)),contentPadding=PaddingValues(horizontal=7.dp,vertical=3.dp)){Text(if(lineupCount==5)t("Lineup 5") else t("⚠ Lineup {count}/5","count" to lineupCount),maxLines=1,softWrap=false,style=MaterialTheme.typography.labelSmall)};if(fullStats)OutlinedButton(onClick=onSubstitution,contentPadding=PaddingValues(horizontal=7.dp,vertical=3.dp)){Text(t("Sub"),maxLines=1,softWrap=false,style=MaterialTheme.typography.labelSmall)};OutlinedButton(onClick=onAddPlayer,contentPadding=PaddingValues(horizontal=7.dp,vertical=3.dp)){Text(t("Players"),maxLines=1,softWrap=false,style=MaterialTheme.typography.labelSmall)}}
        // Each correction button sits midway between the enlarged score and the panel edge:
        // SpaceEvenly gives every gap the same width, so a button's whitespace is equal on both sides.
        Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.SpaceEvenly){
            // Manual scoreboard corrections; they land in the play list as adjustment events.
            OutlinedButton(onClick={onAdjust(-1)},modifier=Modifier.defaultMinSize(minWidth=1.dp,minHeight=1.dp).width(38.dp).height(28.dp),colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=Color.White),contentPadding=PaddingValues(0.dp)){Text("-1",maxLines=1,softWrap=false,style=MaterialTheme.typography.labelMedium)}
            Text(score.toString(),style=MaterialTheme.typography.displayMedium,color=Orange)
            OutlinedButton(onClick={onAdjust(1)},modifier=Modifier.defaultMinSize(minWidth=1.dp,minHeight=1.dp).width(38.dp).height(28.dp),colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=Color.White),contentPadding=PaddingValues(0.dp)){Text("+1",maxLines=1,softWrap=false,style=MaterialTheme.typography.labelMedium)}
        }
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(5.dp)){listOf(2,3).forEach{OutlinedButton(onClick={onPoints(it)},modifier=Modifier.weight(1f),colors=madeColors,border=accentBorder(MadeGreen),contentPadding=PaddingValues(horizontal=5.dp,vertical=4.dp)){Text("+$it")}}}
        if(fullStats){
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(5.dp)){listOf(2,3).forEach{OutlinedButton(onClick={onMiss(it)},modifier=Modifier.weight(1f),colors=missColors,border=accentBorder(MissRed),contentPadding=PaddingValues(horizontal=4.dp,vertical=4.dp)){Text(t("Miss {points}","points" to it))}}}
        OutlinedButton(onClick=onFreeThrow,modifier=Modifier.fillMaxWidth(),colors=freeThrowColors,border=accentBorder(FreeThrowOrange),contentPadding=PaddingValues(horizontal=12.dp,vertical=4.dp)){Text(t("Free Throw"))}
            listOf("REB" to "Rebound","AST" to "Assist","STL" to "Steal","BLK" to "Block").chunked(2).forEach{row->
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(5.dp)){row.forEach{(key,label)->OutlinedButton(onClick={onStat(key)},modifier=Modifier.weight(1f),colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=Color.White),contentPadding=PaddingValues(horizontal=4.dp,vertical=3.dp)){Text(t(label),maxLines=1)}}}
        }
        }
        // Foul is available in both Full Stats and Score + Record modes.
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(5.dp)){
            if(fullStats) OutlinedButton(onClick={onStat("TOV")},modifier=Modifier.weight(1f),colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=Color.White),contentPadding=PaddingValues(horizontal=4.dp,vertical=3.dp)){Text(t("Turnover"),maxLines=1)}
            OutlinedButton(onClick=onFoul,modifier=Modifier.weight(1f),colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.Transparent,contentColor=Color.White),contentPadding=PaddingValues(horizontal=4.dp,vertical=3.dp)){Text(t("Foul"),maxLines=1)}
        }
    }
}

/**
 * 全屏 0-99 号码盘：高亮的号码就是球队名单里的球员，点击可选中/取消选中。
 * 选中的号码会立刻写入球队名单，之后出现在各个球员选择列表里。
 */
@Composable private fun RosterNumbersOverlay(db:HoopDb,teamId:String,teamName:String,onDismiss:()->Unit){
    val context=LocalContext.current
    var version by remember{mutableIntStateOf(0)}
    var nameMode by remember{mutableStateOf(false)}
    // Every tap writes straight through to the roster, so Cancel replays the panel back to how it
    // opened: undo the edits, drop what was added, restore what was removed.
    val opened=remember(teamId){rosterOrder(db.players(teamId))}
    val roster=remember(teamId,version){
        val current=db.players(teamId)
        val byId=current.associateBy{it.id}
        opened.mapNotNull{byId[it.id]}+current.filter{player->opened.none{it.id==player.id}}
    }
    fun cancel(){
        val current=db.players(teamId)
        current.filter{player->opened.none{it.id==player.id}}.forEach{db.deletePlayer(it.id)}
        opened.forEach{before->
            val now=current.firstOrNull{it.id==before.id}
            if(now==null)db.addPlayer(teamId,before.name,before.number)
            else if(now.name!=before.name||now.number!=before.number)db.updatePlayer(before.id,before.name,before.number)
        }
        onDismiss()
    }
    fun playerFor(number:Int):Player?  = roster.firstOrNull{it.number.trim().toIntOrNull()==number}
    Box(Modifier.fillMaxSize()){
        Surface(Modifier.fillMaxSize(),color=PanelBlue,tonalElevation=8.dp){
            Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(DialogScreenMargin),verticalArrangement=Arrangement.spacedBy(6.dp)){
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                    Column(Modifier.weight(1f)){
                        Text(t("Players · {team}","team" to teamName),style=MaterialTheme.typography.titleLarge,color=Ink)
                        Text(if(nameMode)t("Edit numbers and names, or add a new player") else t("Tap a number to add or remove a player"),style=MaterialTheme.typography.bodySmall,color=SecondaryText)
                    }
                    // Numbers mode is the fast path during a game; Names mode is for fixing up the roster.
                    Row(horizontalArrangement=Arrangement.spacedBy(6.dp)){
                        listOf(false to "Numbers",true to "Names").forEach{(mode,label)->
                            Button(
                                onClick={nameMode=mode},
                                contentPadding=PaddingValues(horizontal=14.dp,vertical=6.dp),
                                colors=ButtonDefaults.buttonColors(
                                    containerColor=if(nameMode==mode)Orange else Color(0x22111822),
                                    contentColor=if(nameMode==mode)Color.White else Ink
                                )
                            ){Text(t(label))}
                        }
                    }
                    Spacer(Modifier.width(10.dp))
                    OutlinedButton(onClick={cancel()},contentPadding=PaddingValues(horizontal=18.dp,vertical=6.dp)){Text(t("Cancel"))}
                    Spacer(Modifier.width(6.dp))
                    Button(onClick=onDismiss,contentPadding=PaddingValues(horizontal=18.dp,vertical=6.dp)){Text(t("Done"))}
                }
                if(nameMode)RosterNameEditor(db,teamId,roster,Modifier.fillMaxWidth().weight(1f)){version++}
                else Column(Modifier.fillMaxWidth().weight(1f),verticalArrangement=Arrangement.spacedBy(4.dp)){
                    (0..99).chunked(10).forEach{row->
                        Row(Modifier.fillMaxWidth().weight(1f),horizontalArrangement=Arrangement.spacedBy(4.dp)){
                            row.forEach{number->
                                val player=playerFor(number)
                                val selected=player!=null
                                Button(
                                    onClick={
                                        if(player==null){db.addPlayer(teamId,"",number.toString());version++}
                                        else if(db.playerHasEvents(player.id))Toast.makeText(context,t("#{number} already has recorded stats","number" to number),Toast.LENGTH_SHORT).show()
                                        else{db.deletePlayer(player.id);version++}
                                    },
                                    modifier=Modifier.weight(1f).fillMaxHeight(),
                                    shape=MaterialTheme.shapes.medium,
                                    contentPadding=PaddingValues(0.dp),
                                    colors=ButtonDefaults.buttonColors(
                                        containerColor=if(selected)Orange else Color(0x22111822),
                                        contentColor=if(selected)Color.White else Ink
                                    )
                                ){Text(number.toString(),maxLines=1,style=MaterialTheme.typography.titleMedium)}
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * 名字模式：两列紧凑名单，可以改号码、名、姓，并在底部添加新球员。
 * 全程使用应用内置键盘（`RecorderKeyboard`），避免系统输入法遮挡横屏名单。
 * 编辑就地写库（`updatePlayer`），已记录的数据仍然挂在同一名球员身上。
 * 数据库里球员只有一个 `name` 列（同步/导出都依赖它），所以这里按首个空格拆成名和姓，
 * 保存时再用空格拼回去。
 */
private fun firstNameOf(name:String)=name.trim().substringBefore(' ').trim()
private fun lastNameOf(name:String)=name.trim().substringAfter(' ',"").trim()
private fun fullName(first:String,last:String)=listOf(first.trim(),last.trim()).filter{it.isNotBlank()}.joinToString(" ")

private data class RosterFocus(val playerId:String?,val field:String)

@Composable private fun RosterNameEditor(db:HoopDb,teamId:String,roster:List<Player>,modifier:Modifier=Modifier,onChanged:()->Unit){
    val context=LocalContext.current
    var focus by remember{mutableStateOf<RosterFocus?>(null)}
    var newNumber by remember{mutableStateOf("")}
    var newFirst by remember{mutableStateOf("")}
    var newLast by remember{mutableStateOf("")}
    fun valueOf(player:Player,field:String)=when(field){"number"->player.number;"first"->firstNameOf(player.name);else->lastNameOf(player.name)}
    fun setValue(player:Player,field:String,value:String){
        when(field){
            "number"->db.updatePlayer(player.id,player.name,value)
            "first"->db.updatePlayer(player.id,fullName(value,lastNameOf(player.name)),player.number)
            else->db.updatePlayer(player.id,fullName(firstNameOf(player.name),value),player.number)
        }
        onChanged()
    }
    fun draftValue(field:String)=when(field){"number"->newNumber;"first"->newFirst;else->newLast}
    fun setDraft(field:String,value:String){when(field){"number"->newNumber=value;"first"->newFirst=value;else->newLast=value}}
    fun addDraft(){
        val name=fullName(newFirst,newLast)
        // addPlayer reuses an existing jersey number, so set the name explicitly afterwards.
        val id=db.addPlayer(teamId,name,newNumber.trim())
        db.updatePlayer(id,name,newNumber.trim())
        newNumber="";newFirst="";newLast="";focus=null;onChanged()
    }
    @Composable fun PlayerCell(player:Player,cellModifier:Modifier){
        Row(cellModifier,horizontalArrangement=Arrangement.spacedBy(4.dp),verticalAlignment=Alignment.CenterVertically){
            RecorderInputField("#",player.number,focus==RosterFocus(player.id,"number"),Modifier.width(58.dp),height=40.dp,hideLabelWhenFilled=true){focus=RosterFocus(player.id,"number")}
            RecorderInputField(t("First"),firstNameOf(player.name),focus==RosterFocus(player.id,"first"),Modifier.weight(1f),height=40.dp,hideLabelWhenFilled=true){focus=RosterFocus(player.id,"first")}
            RecorderInputField(t("Last"),lastNameOf(player.name),focus==RosterFocus(player.id,"last"),Modifier.weight(1f),height=40.dp,hideLabelWhenFilled=true){focus=RosterFocus(player.id,"last")}
            TextButton(
                onClick={
                    if(db.playerHasEvents(player.id))Toast.makeText(context,t("{player} already has recorded stats","player" to player.label),Toast.LENGTH_SHORT).show()
                    else{if(focus?.playerId==player.id)focus=null;db.deletePlayer(player.id);onChanged()}
                },
                contentPadding=PaddingValues(horizontal=6.dp,vertical=0.dp),
                modifier=Modifier.width(44.dp)
            ){Text("✕",style=MaterialTheme.typography.titleMedium)}
        }
    }
    Column(modifier,verticalArrangement=Arrangement.spacedBy(6.dp)){
        LazyColumn(Modifier.fillMaxWidth().weight(1f),verticalArrangement=Arrangement.spacedBy(4.dp)){
            items(roster.chunked(2)){pair->
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp)){
                    pair.forEach{player->PlayerCell(player,Modifier.weight(1f))}
                    if(pair.size==1)Spacer(Modifier.weight(1f))
                }
            }
            item{
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(4.dp),verticalAlignment=Alignment.CenterVertically){
                    RecorderInputField("#",newNumber,focus==RosterFocus(null,"number"),Modifier.width(58.dp),height=40.dp,hideLabelWhenFilled=true){focus=RosterFocus(null,"number")}
                    RecorderInputField(t("First"),newFirst,focus==RosterFocus(null,"first"),Modifier.weight(1f),height=40.dp,hideLabelWhenFilled=true){focus=RosterFocus(null,"first")}
                    RecorderInputField(t("Last"),newLast,focus==RosterFocus(null,"last"),Modifier.weight(1f),height=40.dp,hideLabelWhenFilled=true){focus=RosterFocus(null,"last")}
                    Button(
                        enabled=newNumber.isNotBlank()||newFirst.isNotBlank()||newLast.isNotBlank(),
                        onClick={addDraft()},
                        contentPadding=PaddingValues(horizontal=12.dp,vertical=0.dp),
                        modifier=Modifier.height(40.dp)
                    ){Text(t("Add player"),maxLines=1)}
                    Spacer(Modifier.weight(1f))
                }
            }
        }
        if(focus?.field!="number") focus?.let{active->
            val player=active.playerId?.let{id->roster.firstOrNull{it.id==id}}
            if(active.playerId!=null&&player==null)focus=null
            else{
                val current=if(player==null)draftValue(active.field) else valueOf(player,active.field)
                val numeric=active.field=="number"
                fun apply(value:String){if(player==null)setDraft(active.field,value) else setValue(player,active.field,value)}
                RecorderKeyboard(
                    numeric=numeric,
                    onKey={key->apply(if(numeric)(current+key).filter(Char::isDigit).take(3) else (current+key).take(24))},
                    onBackspace={apply(current.dropLast(1))},
                    onClear={apply("")},
                    onDone={focus=null}
                )
            }
        }
        focus?.takeIf{it.field=="number"}?.let{active->
            val player=active.playerId?.let{id->roster.firstOrNull{it.id==id}}
            if(player!=null) NumberInputDialog(valueOf(player,"number"),alignRight=roster.indexOfFirst{it.id==player.id}%2==0,onCancel={focus=null},onSave={value->setValue(player,"number",value);focus=null})
        }
    }
}

@Composable private fun NumberInputDialog(initial:String,alignRight:Boolean,onCancel:()->Unit,onSave:(String)->Unit){
    var value by remember(initial){mutableStateOf(initial)}
    Popup(alignment=if(alignRight)Alignment.CenterEnd else Alignment.CenterStart, onDismissRequest=onCancel, properties=PopupProperties(focusable=true, dismissOnBackPress=true, dismissOnClickOutside=true)){
        Surface(Modifier.padding(20.dp).widthIn(min=280.dp,max=360.dp),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
            Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(6.dp)){
                Text(t("Player number"),style=MaterialTheme.typography.titleLarge,color=Ink)
                Text(value.ifBlank{"—"},modifier=Modifier.fillMaxWidth(),textAlign=TextAlign.Center,style=MaterialTheme.typography.headlineMedium,color=Orange)
                listOf(listOf("1","2","3"),listOf("4","5","6"),listOf("7","8","9"),listOf("0")).forEach{row->
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(6.dp)){
                        row.forEach{key->OutlinedButton(onClick={value=(value+key).take(3)},modifier=Modifier.weight(1f).height(48.dp),contentPadding=PaddingValues(0.dp)){Text(key,style=MaterialTheme.typography.titleLarge)}}
                        repeat(3-row.size){Spacer(Modifier.weight(1f))}
                    }
                }
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(6.dp)){
                    OutlinedButton(onClick=onCancel,modifier=Modifier.weight(1f)){Text(t("Cancel"),maxLines=1)}
                    OutlinedButton(onClick={value=value.dropLast(1)},modifier=Modifier.weight(1f)){Text(t("Delete"),maxLines=1)}
                    Button(onClick={onSave(value)},modifier=Modifier.weight(1f)){Text(t("OK"),maxLines=1)}
                }
            }
        }
    }
}

@Composable private fun PlaysDialog(db:HoopDb,game:Game,events:List<StatEvent>,onDismiss:()->Unit,onChanged:()->Unit={}){
    var filter by remember{mutableStateOf(PlayFilter.ALL)}
    ScreenDialog(onDismiss){
        Surface(Modifier.fillMaxSize(),color=PanelBlue,shape=MaterialTheme.shapes.extraLarge,tonalElevation=8.dp){
            Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(6.dp),verticalAlignment=Alignment.CenterVertically){
                    Text(t("{count} recorded actions","count" to events.size),Modifier.weight(1f),color=SecondaryText,style=MaterialTheme.typography.bodySmall)
                    PlayFilter.entries.forEach{option->
                        FilterChip(selected=filter==option,onClick={filter=option},label={Text(t(option.label),maxLines=1)})
                    }
                    TextButton(onClick=onDismiss,modifier=Modifier.sizeIn(minWidth=48.dp,minHeight=48.dp)){Text("×",style=MaterialTheme.typography.headlineSmall)}
                }
                EventTimeline(db,game,events,Modifier.fillMaxWidth().weight(1f),editable=true,autoScrollToLatest=true,filter=filter,onChanged=onChanged)
            }
        }
    }
}

@Composable private fun GameStatsDialog(db:HoopDb,game:Game,onDismiss:()->Unit){
    val context=LocalContext.current
    val view=LocalView.current
    val scope=rememberCoroutineScope()
    val events=db.events(game.id).filterNot{it.reverted}
    var selectedTeam by remember{mutableIntStateOf(0)}
    var immersive by remember{mutableStateOf(false)}
    var showColumnPicker by remember{mutableStateOf(false)}
    var visibleColumns by remember{mutableStateOf(STAT_COLUMNS.map{it.key}.toSet())}
    // Tapping a stat header cycles descending → ascending → back to the default roster order.
    var statSortKey by remember{mutableStateOf<String?>(null)}
    var statSortAscending by remember{mutableStateOf(false)}
    fun toggleStatSort(key:String){if(statSortKey!=key){statSortKey=key;statSortAscending=false} else if(!statSortAscending)statSortAscending=true else {statSortKey=null;statSortAscending=false}}
    // The orientation to return to is captured when full screen is entered, not when this screen
    // composes (the previous page's cleanup has not run yet at that point), and it is only restored
    // if full screen is still active when the screen goes away.
    var baseOrientation by remember{mutableIntStateOf(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)}
    fun toggleFullscreen(enabled:Boolean){if(enabled&&!immersive)baseOrientation=(context as? ComponentActivity)?.requestedOrientation?:ActivityInfo.SCREEN_ORIENTATION_PORTRAIT;immersive=enabled;setStatsFullscreen(context,view,enabled,baseOrientation)}
    DisposableEffect(Unit){onDispose{if(immersive)setStatsFullscreen(context,view,false,baseOrientation)}}
    ScreenDialog(onDismiss,fullScreen=true){
        Surface(
            Modifier.fillMaxSize(),
            color=CardBlue,
            contentColor=Ink,
            shape=RectangleShape
        ){
            Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal=6.dp,vertical=2.dp),verticalArrangement=Arrangement.spacedBy(2.dp)){
                // The close control shares the team-tab row, at the same size as the team names, so the
                // panel does not waste a whole line on it.
                Row(Modifier.fillMaxWidth().height(30.dp),verticalAlignment=Alignment.CenterVertically){
                    TabRow(selectedTabIndex=selectedTeam,modifier=Modifier.weight(1f).fillMaxHeight(),containerColor=CardBlue,contentColor=Orange){
                        // Both labels are orange, so the selected tab also carries a tinted background.
                        listOf(0 to t("{team} (H)","team" to game.homeName),1 to t("{team} (A)","team" to game.awayName)).forEach{(index,label)->
                            val selected=selectedTeam==index
                            Tab(
                                selected=selected,
                                onClick={selectedTeam=index},
                                modifier=Modifier.background(if(selected)Orange.copy(alpha=.16f) else Color.Transparent),
                                text={Text(label,maxLines=1,color=if(selected)Orange else SecondaryText,style=MaterialTheme.typography.labelLarge)}
                            )
                        }
                    }
                    TextButton(onClick={toggleFullscreen(!immersive)},contentPadding=PaddingValues(horizontal=8.dp)){Text(if(immersive)"X" else t("Full screen"),color=Orange,maxLines=1,style=MaterialTheme.typography.labelSmall)}
                    TextButton(onClick=onDismiss,contentPadding=PaddingValues(horizontal=8.dp)){Text("X",color=Orange,style=MaterialTheme.typography.labelLarge)}
                }
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                    Text(t("Statistics"),Modifier.weight(1f),style=MaterialTheme.typography.titleSmall,color=Ink)
                    TextButton(onClick={showColumnPicker=true}){Text(t("Select columns"),maxLines=1)}
                }
                StatsHeader(visibleColumns,statSortKey,statSortAscending,onSort=::toggleStatSort)
                Box(Modifier.fillMaxWidth().weight(1f)){
                    if(selectedTeam==0)TeamStats(db,game.homeId,events,game.id,fitScreen=true,contentColor=Ink,visibleColumns=visibleColumns,sortKey=statSortKey,sortAscending=statSortAscending) else TeamStats(db,game.awayId,events,game.id,fitScreen=true,contentColor=Ink,visibleColumns=visibleColumns,sortKey=statSortKey,sortAscending=statSortAscending)
                }
            }
        }
        if(showColumnPicker)StatColumnDialog(visibleColumns,{visibleColumns=it;showColumnPicker=false},{showColumnPicker=false})
    }
}

private data class StatColumn(val key:String,val label:String)
private val STAT_COLUMNS=listOf("MIN","PTS","+/-","FGM","FGA","FG%","3PM","3PA","3P%","FTM","FTA","FT%","OREB","DREB","REB","AST","STL","BLK","TO","PF").map{StatColumn(it,it)}

@Composable private fun StatColumnDialog(selected:Set<String>,onSave:(Set<String>)->Unit,onDismiss:()->Unit){
    var draft by remember(selected){mutableStateOf(selected)}
    AlertDialog(onDismissRequest=onDismiss,title={Text(t("Select columns"))},text={Column(Modifier.verticalScroll(rememberScrollState())){STAT_COLUMNS.forEach{c->Row(Modifier.fillMaxWidth().clickable{draft=if(c.key in draft)draft-c.key else draft+c.key},verticalAlignment=Alignment.CenterVertically){Checkbox(c.key in draft,{draft=if(it)draft+c.key else draft-c.key});Text(c.label)}}}},confirmButton={TextButton(enabled=draft.isNotEmpty(),onClick={onSave(draft)}){Text(t("Apply"))}},dismissButton={TextButton(onClick=onDismiss){Text(t("Cancel"))}})
}

@Composable private fun TeamStats(db:HoopDb,teamId:String,events:List<StatEvent>,gameId:String,fitScreen:Boolean=false,contentColor:Color=Ink,visibleColumns:Set<String> = STAT_COLUMNS.map{it.key}.toSet(),sortKey:String?=null,sortAscending:Boolean=false){
    val teamEvents=events.filter{it.teamId==teamId && !it.reverted}
    // Match Web: include the complete roster, even when a player has no recorded action.
    val players=rosterOrder(db.players(teamId))
    val persisted=db.playerGameStats(gameId)
    // Each row is computed up front so the table can sort by any column; percentages with no
    // attempts rank below 0% instead of above 100%.
    fun percentValue(made:Int,attempts:Int)=if(attempts==0)-1.0 else made*100.0/attempts
    fun line(label:String,playerEvents:List<StatEvent>,saved:Pair<Long,Int>?):Triple<String,Map<String,String>,Map<String,Double>>{
        fun total(vararg types:String)=playerEvents.filter{it.type in types}.sumOf{it.value}
        // Includes manual +1/-1 adjustments (team plays) so the points column adds up to the scoreboard.
        val points=playerEvents.filter{isScoringType(it.type)}.sumOf{it.value}
        val (twoMade,twoAttempts,twoPercent)=fieldGoals(playerEvents,2)
        val (threeMade,threeAttempts,threePercent)=fieldGoals(playerEvents,3)
        val (ftMade,ftAttempts,ftPercent)=freeThrows(playerEvents)
        val fgm=twoMade+threeMade;val fga=twoAttempts+threeAttempts
        val display=mapOf("MIN" to (saved?.let{formatClock(it.first)}?:"—"),"FGM" to fgm.toString(),"FGA" to fga.toString(),"FG%" to shootingPercent(fgm,fga),"3PM" to threeMade.toString(),"3PA" to threeAttempts.toString(),"3P%" to threePercent,"FTM" to ftMade.toString(),"FTA" to ftAttempts.toString(),"FT%" to ftPercent,"OREB" to total("OREB").toString(),"DREB" to total("DREB").toString(),"REB" to total("REB").toString(),"AST" to total("AST").toString(),"STL" to total("STL").toString(),"BLK" to total("BLK").toString(),"TO" to total("TOV").toString(),"PF" to total("FOUL").toString(),"PTS" to points.toString(),"+/-" to (saved?.second?.toString()?:"—"))
        val numeric=mapOf("MIN" to (saved?.first?.toDouble()?:0.0),"FGM" to fgm.toDouble(),"FGA" to fga.toDouble(),"FG%" to percentValue(fgm,fga),"3PM" to threeMade.toDouble(),"3PA" to threeAttempts.toDouble(),"3P%" to percentValue(threeMade,threeAttempts),"FTM" to ftMade.toDouble(),"FTA" to ftAttempts.toDouble(),"FT%" to percentValue(ftMade,ftAttempts),"OREB" to total("OREB").toDouble(),"DREB" to total("DREB").toDouble(),"REB" to total("REB").toDouble(),"AST" to total("AST").toDouble(),"STL" to total("STL").toDouble(),"BLK" to total("BLK").toDouble(),"TO" to total("TOV").toDouble(),"PF" to total("FOUL").toDouble(),"PTS" to points.toDouble(),"+/-" to (saved?.second?.toDouble()?:0.0))
        return Triple(label,display,numeric)
    }
    val unassigned=teamEvents.filter{it.playerId==null&&it.type!="VIDEO"}
    // Plays recorded with "Assign later" still belong to the team; list them so the rows add up to the total.
    val lines=players.map{player->line(player.label,teamEvents.filter{it.playerId==player.id},persisted[player.id]?:(0L to 0))}+(if(unassigned.isEmpty())emptyList() else listOf(line(t("Unassigned"),unassigned,null)))
    // Sorting is stable, so equal values keep the roster order as a tie-break.
    val ordered=when{
        sortKey==null->lines
        sortAscending->lines.sortedBy{it.third[sortKey]?:0.0}
        else->lines.sortedByDescending{it.third[sortKey]?:0.0}
    }
    // Rows keep a fixed height that fits their text. Sharing the panel height evenly used to squeeze
    // the lines together and clip them once the roster grew, so the list scrolls instead.
    val playerRows:@Composable ()->Unit = {
        ordered.forEach{(label,display,_)->
            Row(Modifier.fillMaxWidth().height(STATS_ROW_HEIGHT),verticalAlignment=Alignment.CenterVertically){
                StatCell(label,2.0f,TextAlign.Start,contentColor,fontSize=8.sp)
                STAT_COLUMNS.forEach{column->if(column.key in visibleColumns)StatCell(display[column.key].orEmpty(),color=contentColor)}
            }
            HorizontalDivider(color=Color(0xFFD0D3D8))
        }
        if(players.isEmpty())Box(Modifier.fillMaxWidth().height(STATS_ROW_HEIGHT),contentAlignment=Alignment.Center){
            Text(t("No stats recorded yet."),color=SecondaryText,style=MaterialTheme.typography.bodySmall)
        }
    }
    fun teamTotal(type:String)=teamEvents.filter{it.type==type}.sumOf{it.value}
    // Includes manual +1/-1 adjustments so the team total always matches the scoreboard.
    val points=teamEvents.filter{isScoringType(it.type)}.sumOf{it.value}
    // In screen-filling tables only player rows scroll; the total remains visible at the bottom.
    val pinTotals=fitScreen
    val totalRow:@Composable ()->Unit = {
        Row(Modifier.fillMaxWidth().height(STATS_ROW_HEIGHT).background(Color(0xFFE2E4E8)),verticalAlignment=Alignment.CenterVertically){
            StatCell(t("Team Total"),2.0f,TextAlign.Start,contentColor,fontSize=8.sp)
            val (teamTwoMade,teamTwoAttempts,teamTwoPercent)=fieldGoals(teamEvents,2)
            val (teamThreeMade,teamThreeAttempts,teamThreePercent)=fieldGoals(teamEvents,3)
            val (teamFtMade,teamFtAttempts,teamFtPercent)=freeThrows(teamEvents)
            val teamFgm=teamTwoMade+teamThreeMade;val teamFga=teamTwoAttempts+teamThreeAttempts
            // Box-score convention: the team total is five man-minutes per elapsed game minute
            // (8:00 × 4 periods × 5 players = 160:00), not the sum of the per-player attribution,
            // which under-counts whenever the lineup was never recorded for a stretch.
            val liveGame=db.games().firstOrNull{it.id==gameId}
            val gameElapsedMs=liveGame?.let{(it.currentPeriod-1).coerceAtLeast(0)*it.periodDurationMs+(it.periodDurationMs-it.clockRemainingMs).coerceAtLeast(0)}?:0L
            val teamMinutes=gameElapsedMs*5
            val scoring=events.filter{!it.reverted&&isScoringType(it.type)}
            val teamPm=scoring.filter{it.teamId==teamId}.sumOf{it.value}-scoring.filter{it.teamId!=teamId}.sumOf{it.value}
            val values=mapOf("MIN" to formatClock(teamMinutes),"FGM" to teamFgm.toString(),"FGA" to teamFga.toString(),"FG%" to shootingPercent(teamFgm,teamFga),"3PM" to teamThreeMade.toString(),"3PA" to teamThreeAttempts.toString(),"3P%" to teamThreePercent,"FTM" to teamFtMade.toString(),"FTA" to teamFtAttempts.toString(),"FT%" to teamFtPercent,"OREB" to teamTotal("OREB").toString(),"DREB" to teamTotal("DREB").toString(),"REB" to teamTotal("REB").toString(),"AST" to teamTotal("AST").toString(),"STL" to teamTotal("STL").toString(),"BLK" to teamTotal("BLK").toString(),"TO" to teamTotal("TOV").toString(),"PF" to teamTotal("FOUL").toString(),"PTS" to points.toString(),"+/-" to teamPm.toString())
            // Keep totals in the same order as the header and player rows. The map's
            // declaration order is not the user's current column order.
            STAT_COLUMNS.forEach{column->if(column.key in visibleColumns)StatCell(values[column.key].orEmpty(),color=contentColor)}
        }
    }
    Column(if(fitScreen)Modifier.fillMaxSize() else Modifier){
        if(fitScreen)Column(Modifier.weight(1f).verticalScroll(rememberScrollState())){playerRows();if(!pinTotals)totalRow()} else {playerRows();totalRow()}
        if(pinTotals)totalRow()
    }
}

private val STATS_ROW_HEIGHT = 22.dp

private fun shootingPercent(made:Int,attempts:Int)=if(attempts==0)"—" else String.format(Locale.US,"%.1f%%",made*100.0/attempts)

/** Free throws come from their own event types rather than the field-goal ones. */
private fun freeThrows(events:List<StatEvent>):Triple<Int,Int,String>{
    val made=events.count{it.type=="FT_MADE"}
    val attempts=made+events.count{it.type=="FT_MISS"}
    return Triple(made,attempts,shootingPercent(made,attempts))
}

/** Two- and three-pointers are counted separately: made are PTS_2/PTS_3, misses are MISS_2/MISS_3. */
private fun fieldGoals(events:List<StatEvent>,points:Int):Triple<Int,Int,String>{
    val made=events.count{it.type=="PTS_$points"}
    val attempts=made+events.count{it.type=="MISS_$points"}
    return Triple(made,attempts,shootingPercent(made,attempts))
}

@Composable private fun StatsHeader(visibleColumns:Set<String> = STAT_COLUMNS.map{it.key}.toSet(),sortKey:String?=null,sortAscending:Boolean=false,onSort:((String)->Unit)?=null){
    Row(Modifier.fillMaxWidth().background(Orange).padding(vertical=2.dp),verticalAlignment=Alignment.CenterVertically){
        StatCell(t("Player"),2.0f,TextAlign.Start,Ink)
        STAT_COLUMNS.filter{it.key in visibleColumns}.forEach{column->
            // The active sort column carries its direction arrow right in the header label.
            val label=if(column.key==sortKey)"${column.label}${if(sortAscending)"▲" else "▼"}" else column.label
            StatCell(label,color=Ink,onClick=onSort?.let{sort->{sort(column.key)}})
        }
    }
}

// The table carries 13 columns, so on a narrow screen a cell has barely 60dp: the text is scaled
// down to fit instead of being clipped, which turned "2PM" and "2PA" into two identical "2P".
@Composable private fun RowScope.StatCell(value:String,weight:Float=1f,textAlign:TextAlign=TextAlign.Center,color:Color=Ink,fontSize:androidx.compose.ui.unit.TextUnit=9.sp,onClick:(()->Unit)?=null){
    Text(
        value,
        Modifier.weight(weight).let{if(onClick!=null)it.clickable(onClick=onClick) else it}.padding(horizontal=1.dp),
        color=color,
        style=MaterialTheme.typography.labelSmall.copy(fontSize=fontSize,lineHeight=12.sp),
        textAlign=textAlign,
        maxLines=1,
        softWrap=false,
        overflow=TextOverflow.Clip
    )
}

private fun <T> ((T)->Unit).bind(value:T):()->Unit = { this(value) }
private fun formatClock(ms:Long)=String.format(Locale.US,"%02d:%02d",ms/60000,(ms/1000)%60)
private fun exportCsv(context:android.content.Context,db:HoopDb,game:Game){val file=File(context.getExternalFilesDir(null),"HoopReplay_${game.id}_events.csv");file.bufferedWriter().use{w->w.appendLine("event_id,team_id,player_id,event_type,value,period,game_clock_ms,video_time_ms,reverted");db.events(game.id).forEach{e->w.appendLine("${e.id},${e.teamId},${e.playerId?:""},${e.type},${e.value},${e.period},${e.gameClockMs},${e.finalVideoTimeMs},${e.reverted}")}}}

/** Keeps a team name usable in a file name: every non-alphanumeric character is dropped. */
private fun fileNamePart(name:String):String=
    name.replace(Regex("[^A-Za-z0-9]"),"").ifBlank{"Team"}

/** Exports share one name: HoopReplay-Home-Away-yyyyMMdd-HHmmss.<extension>. */
private fun exportFileName(game:Game,extension:String):String{
    val stamp=java.text.SimpleDateFormat("yyyyMMdd-HHmmss",java.util.Locale.US).format(java.util.Date())
    return "HoopReplay-${fileNamePart(game.homeName)}-${fileNamePart(game.awayName)}-$stamp.$extension"
}

internal fun exportGameJsonFile(context:android.content.Context,db:HoopDb,game:Game):String{
    val fileName=exportFileName(game,"json")
    val values=ContentValues().apply{
        put(MediaStore.MediaColumns.DISPLAY_NAME,fileName)
        put(MediaStore.MediaColumns.MIME_TYPE,"application/json")
        put(MediaStore.MediaColumns.RELATIVE_PATH,"${Environment.DIRECTORY_DOWNLOADS}/HoopReplay")
    }
    val uri=requireNotNull(context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values)){t("Could not create JSON file")}
    try{
        context.contentResolver.openOutputStream(uri,"w")!!.bufferedWriter().use{it.write(db.exportGameJson(game).toString(2))}
        return fileName
    }catch(error:Throwable){
        context.contentResolver.delete(uri,null,null)
        throw error
    }
}

internal fun importGameJsonFile(context:android.content.Context,db:HoopDb,uri:android.net.Uri):GameImport{
    val text=requireNotNull(context.contentResolver.openInputStream(uri)){t("Could not open file")}.bufferedReader().use{it.readText()}
    return db.importGameJson(org.json.JSONObject(text))
}

private data class PdfStatRow(val player:String,val pts:Int,val twoMade:Int,val twoAttempts:Int,val threeMade:Int,val threeAttempts:Int,val ftMade:Int,val ftAttempts:Int,val reb:Int,val ast:Int,val stl:Int,val blk:Int,val tov:Int,val pf:Int)

private fun pdfStatRows(db:HoopDb,teamId:String,events:List<StatEvent>):List<PdfStatRow>{
    val teamEvents=events.filter{it.teamId==teamId}
    fun row(label:String,playerEvents:List<StatEvent>):PdfStatRow{
        val (twoMade,twoAttempts,_)=fieldGoals(playerEvents,2)
        val (threeMade,threeAttempts,_)=fieldGoals(playerEvents,3)
        val (ftMade,ftAttempts,_)=freeThrows(playerEvents)
        return PdfStatRow(
            label,
            playerEvents.filter{isScoringType(it.type)}.sumOf{it.value},
            twoMade,
            twoAttempts,
            threeMade,
            threeAttempts,
            ftMade,
            ftAttempts,
            playerEvents.filter{it.type=="REB"}.sumOf{it.value},
            playerEvents.filter{it.type=="AST"}.sumOf{it.value},
            playerEvents.filter{it.type=="STL"}.sumOf{it.value},
            playerEvents.filter{it.type=="BLK"}.sumOf{it.value},
            playerEvents.filter{it.type=="TOV"}.sumOf{it.value},
            playerEvents.filter{it.type=="FOUL"}.sumOf{it.value}
        )
    }
    val unassigned=teamEvents.filter{it.playerId==null&&it.type!="VIDEO"}
    // Plays recorded with "Assign later" still belong to the team; list them so the rows add up to the total.
    return db.players(teamId).map{player->row(player.label,teamEvents.filter{it.playerId==player.id})}+(if(unassigned.isEmpty())emptyList() else listOf(row(t("Unassigned"),unassigned)))
}

/**
 * Statistics export uses US Letter in landscape (792x612) and stacks both teams on one page, which
 * fits a normal roster; a team that is too long for the shared page continues on its own page.
 */
/** Draws the app icon as the letterhead logo on an exported PDF page. */
private fun drawPdfLogo(context:android.content.Context,canvas:android.graphics.Canvas,left:Float,top:Float,size:Float){
    // The launcher icon is an adaptive icon, so it has to be drawn through its Drawable —
    // BitmapFactory cannot decode the XML and silently returns null.
    val logo=context.getDrawable(R.mipmap.ic_launcher)?:return
    logo.setBounds(left.toInt(),top.toInt(),(left+size).toInt(),(top+size).toInt())
    logo.draw(canvas)
}

internal fun exportStatsPdf(context:android.content.Context,db:HoopDb,game:Game):String{
    val events=db.events(game.id).filterNot{it.reverted}
    val fileName=exportFileName(game,"pdf")
    val values=ContentValues().apply{
        put(MediaStore.MediaColumns.DISPLAY_NAME,fileName)
        put(MediaStore.MediaColumns.MIME_TYPE,"application/pdf")
        put(MediaStore.MediaColumns.RELATIVE_PATH,"${Environment.DIRECTORY_DOWNLOADS}/HoopReplay")
    }
    val uri=requireNotNull(context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values)){t("Could not create PDF file")}
    val document=PdfDocument()
    val pageWidth=792
    val pageHeight=612
    val leftEdge=32f
    val rightEdge=760f
    // One x per column: player name, then the 16 stat columns the on-screen table shows.
    val xs=listOf(36f,205f,239f,273f,307f,341f,375f,409f,443f,477f,511f,545f,579f,613f,647f,681f,715f)
    val rowHeight=15f
    val sharedPageRows=12
    fun drawTeamBlock(canvas:android.graphics.Canvas,paint:Paint,top:Float,teamName:String,rows:List<PdfStatRow>,partLabel:String,withTotal:Boolean):Float{
        paint.textSize=15f;paint.isFakeBoldText=true;paint.color=android.graphics.Color.rgb(255,107,0)
        canvas.drawText("$teamName$partLabel",36f,top,paint)
        paint.color=android.graphics.Color.rgb(45,48,54)
        canvas.drawRect(leftEdge,top+8f,rightEdge,top+30f,paint)
        paint.color=android.graphics.Color.WHITE;paint.textSize=10f
        listOf(t("Player"),"PTS","2PM","2PA","2P%","3PM","3PA","3P%","FTM","FTA","FT%","REB","AST","STL","BLK","TOV","PF").forEachIndexed{i,label->canvas.drawText(label,xs[i],top+24f,paint)}
        var y=top+45f
        paint.isFakeBoldText=false;paint.textSize=10f
        rows.forEachIndexed{index,row->
            if(index%2==1){paint.color=android.graphics.Color.rgb(242,243,245);canvas.drawRect(leftEdge,y-11f,rightEdge,y+4f,paint)}
            paint.color=android.graphics.Color.rgb(30,32,36)
            listOf(row.player,row.pts.toString(),row.twoMade.toString(),row.twoAttempts.toString(),shootingPercent(row.twoMade,row.twoAttempts),row.threeMade.toString(),row.threeAttempts.toString(),shootingPercent(row.threeMade,row.threeAttempts),row.ftMade.toString(),row.ftAttempts.toString(),shootingPercent(row.ftMade,row.ftAttempts),row.reb.toString(),row.ast.toString(),row.stl.toString(),row.blk.toString(),row.tov.toString(),row.pf.toString())
                .forEachIndexed{i,value->canvas.drawText(value.take(if(i==0)24 else 4),xs[i],y,paint)}
            y+=rowHeight
        }
        if(withTotal){
            paint.color=android.graphics.Color.rgb(255,107,0);paint.isFakeBoldText=true
            val twoMade=rows.sumOf{it.twoMade};val twoAttempts=rows.sumOf{it.twoAttempts}
            val threeMade=rows.sumOf{it.threeMade};val threeAttempts=rows.sumOf{it.threeAttempts}
            val ftMade=rows.sumOf{it.ftMade};val ftAttempts=rows.sumOf{it.ftAttempts}
            listOf(t("Team Total"),rows.sumOf{it.pts}.toString(),twoMade.toString(),twoAttempts.toString(),shootingPercent(twoMade,twoAttempts),threeMade.toString(),threeAttempts.toString(),shootingPercent(threeMade,threeAttempts),ftMade.toString(),ftAttempts.toString(),shootingPercent(ftMade,ftAttempts),rows.sumOf{it.reb}.toString(),rows.sumOf{it.ast}.toString(),rows.sumOf{it.stl}.toString(),rows.sumOf{it.blk}.toString(),rows.sumOf{it.tov}.toString(),rows.sumOf{it.pf}.toString())
                .forEachIndexed{i,value->canvas.drawText(value,xs[i],y+3f,paint)}
            paint.isFakeBoldText=false
            y+=rowHeight+3f
        }
        return y
    }
    fun drawHeader(canvas:android.graphics.Canvas,paint:Paint){
        paint.textAlign=Paint.Align.LEFT
        drawPdfLogo(context,canvas,36f,24f,48f)
        val textLeft=96f
        paint.color=android.graphics.Color.rgb(22,24,29);paint.textSize=22f;paint.isFakeBoldText=true
        canvas.drawText(t("HoopReplay Game Statistics"),textLeft,42f,paint)
        paint.textSize=11f;paint.isFakeBoldText=false;paint.color=android.graphics.Color.DKGRAY
        canvas.drawText("${game.title}  |  ${formatGameDateTime(game.scheduledAt)}",textLeft,63f,paint)
        canvas.drawText("${game.homeName} ${game.homeScore} - ${game.awayScore} ${game.awayName}",textLeft,80f,paint)
    }
    fun drawFooter(canvas:android.graphics.Canvas,paint:Paint){
        paint.textSize=9f;paint.isFakeBoldText=false;paint.color=android.graphics.Color.GRAY
        canvas.drawText(t("Generated by HoopReplay"),36f,pageHeight-22f,paint)
    }
    try{
        val teams=listOf(game.homeName to game.homeId,game.awayName to game.awayId).map{(name,id)->name to pdfStatRows(db,id,events)}
        var pageNumber=1
        val page=document.startPage(PdfDocument.PageInfo.Builder(pageWidth,pageHeight,pageNumber++).create())
        val paint=Paint(Paint.ANTI_ALIAS_FLAG)
        drawHeader(page.canvas,paint)
        var y=112f
        val overflow=mutableListOf<Pair<String,List<PdfStatRow>>>()
        teams.forEach{(name,rows)->
            val onThisPage=rows.take(sharedPageRows)
            val rest=rows.drop(sharedPageRows)
            val label=if(rest.isEmpty())"" else " (1/${(rows.size+sharedPageRows-1)/sharedPageRows})"
            y=drawTeamBlock(page.canvas,paint,y,name,onThisPage,label,rest.isEmpty())+26f
            if(rest.isNotEmpty())overflow+=name to rest
        }
        drawFooter(page.canvas,paint)
        document.finishPage(page)
        // Only a roster longer than the shared page needs extra pages; both teams stay together otherwise.
        overflow.forEach{(name,rest)->
            rest.chunked(24).forEachIndexed{index,chunk->
                val extra=document.startPage(PdfDocument.PageInfo.Builder(pageWidth,pageHeight,pageNumber++).create())
                val extraPaint=Paint(Paint.ANTI_ALIAS_FLAG)
                drawHeader(extra.canvas,extraPaint)
                drawTeamBlock(extra.canvas,extraPaint,112f,name,chunk," ${t("(continued {page})","page" to index+2)}",index==(rest.size-1)/24)
                drawFooter(extra.canvas,extraPaint)
                document.finishPage(extra)
            }
        }
        context.contentResolver.openOutputStream(uri,"w")!!.use(document::writeTo)
        return fileName
    }catch(error:Throwable){
        context.contentResolver.delete(uri,null,null)
        throw error
    }finally{document.close()}
}

private data class PdfPlayRow(val period:Int,val clock:String,val team:String,val player:String,val play:String,val score:String,val scored:Boolean)

private fun pdfPlayRows(db:HoopDb,game:Game,events:List<StatEvent>):List<PdfPlayRow>{
    val players=(db.players(game.homeId)+db.players(game.awayId)).associateBy{it.id}
    val ordered=events.sortedWith(compareBy<StatEvent>{it.period}.thenByDescending{it.gameClockMs}.thenBy{it.id})
    var homeScore=0
    var awayScore=0
    return ordered.map{event->
        val scored=isScoringType(event.type)
        if(scored&&event.teamId==game.homeId)homeScore+=event.value
        if(scored&&event.teamId==game.awayId)awayScore+=event.value
        PdfPlayRow(
            event.period,
            formatClock(event.gameClockMs),
            if(event.teamId==game.homeId)game.homeName else game.awayName,
            if(event.type=="ADJ")"" else event.playerId?.let{players[it]}?.let{it.label}?:t("Unassigned"),
            t(eventLabel(event)),
            "$awayScore - $homeScore",
            scored
        )
    }
}

/**
 * Play-by-play export mirrors the on-screen timeline: the clock runs down the middle, the away team
 * is on the left and the home team on the right, so the PDF reads like the app.
 */
internal fun exportPlaysPdf(context:android.content.Context,db:HoopDb,game:Game):String{
    val events=db.events(game.id).filterNot{it.reverted}
    val rows=pdfPlayRows(db,game,events)
    val fileName=exportFileName(game,"pdf")
    val values=ContentValues().apply{
        put(MediaStore.MediaColumns.DISPLAY_NAME,fileName)
        put(MediaStore.MediaColumns.MIME_TYPE,"application/pdf")
        put(MediaStore.MediaColumns.RELATIVE_PATH,"${Environment.DIRECTORY_DOWNLOADS}/HoopReplay")
    }
    val uri=requireNotNull(context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values)){t("Could not create PDF file")}
    val document=PdfDocument()
    val awayColumnRight=372f
    val centerLeft=384f
    val centerRight=458f
    val homeColumnLeft=470f
    try{
        val pages=rows.chunked(11).ifEmpty{listOf(emptyList())}
        pages.forEachIndexed{partIndex,pageRows->
            val page=document.startPage(PdfDocument.PageInfo.Builder(842,595,partIndex+1).create())
            val canvas=page.canvas
            val paint=Paint(Paint.ANTI_ALIAS_FLAG).apply{color=android.graphics.Color.rgb(22,24,29);textSize=24f;isFakeBoldText=true}
            drawPdfLogo(context,canvas,36f,26f,52f)
            val headerTextLeft=100f
            canvas.drawText(t("HoopReplay Play-by-Play"),headerTextLeft,44f,paint)
            paint.textSize=13f;paint.isFakeBoldText=false;paint.color=android.graphics.Color.DKGRAY
            canvas.drawText("${game.title}  |  ${formatGameDateTime(game.scheduledAt)}",headerTextLeft,70f,paint)
            canvas.drawText("${game.homeName} ${game.homeScore} - ${game.awayScore} ${game.awayName}",headerTextLeft,91f,paint)
            // Column headers name the side each half of the page belongs to, like the app's timeline.
            paint.textSize=12f;paint.isFakeBoldText=true;paint.color=android.graphics.Color.rgb(255,107,0)
            paint.textAlign=Paint.Align.CENTER
            canvas.drawText(t("{team} (Away)","team" to game.awayName).take(46),(36f+awayColumnRight)/2,123f,paint)
            canvas.drawText(if(pages.size>1)t("Time ({page}/{count})","page" to partIndex+1,"count" to pages.size) else t("Time"),(centerLeft+centerRight)/2,123f,paint)
            canvas.drawText(t("{team} (Home)","team" to game.homeName).take(46),(homeColumnLeft+806f)/2,123f,paint)
            paint.textAlign=Paint.Align.LEFT
            paint.color=android.graphics.Color.rgb(220,222,226)
            canvas.drawRect(32f,132f,810f,133f,paint)
            var y=160f
            pageRows.forEach{row->
                val isHome=row.team==game.homeName
                if(row.scored){paint.color=android.graphics.Color.rgb(248,249,250);canvas.drawRect(32f,y-18f,810f,y+22f,paint)}
                // The clock column stays centered between the two sides.
                paint.textAlign=Paint.Align.CENTER
                paint.textSize=10f;paint.isFakeBoldText=true;paint.color=android.graphics.Color.rgb(255,107,0)
                canvas.drawText(periodShortLabel(row.period,game.periodCount),(centerLeft+centerRight)/2,y-6f,paint)
                paint.textSize=14f;paint.color=android.graphics.Color.rgb(22,24,29)
                canvas.drawText(row.clock,(centerLeft+centerRight)/2,y+12f,paint)
                if(row.scored){paint.textSize=10f;paint.isFakeBoldText=false;paint.color=android.graphics.Color.rgb(90,94,100);canvas.drawText(row.score,(centerLeft+centerRight)/2,y+26f,paint)}
                // Away plays hug the middle from the left, home plays from the right.
                paint.textAlign=if(isHome)Paint.Align.LEFT else Paint.Align.RIGHT
                val x=if(isHome)homeColumnLeft else awayColumnRight
                paint.textSize=12f;paint.isFakeBoldText=true;paint.color=android.graphics.Color.rgb(22,24,29)
                canvas.drawText(row.player.take(34),x,y-2f,paint)
                paint.textSize=11f;paint.isFakeBoldText=false;paint.color=android.graphics.Color.rgb(90,94,100)
                canvas.drawText(row.play.take(38),x,y+14f,paint)
                paint.textAlign=Paint.Align.LEFT
                y+=40f
            }
            paint.textAlign=Paint.Align.LEFT
            paint.textSize=9f;paint.isFakeBoldText=false;paint.color=android.graphics.Color.GRAY
            canvas.drawText(t("Generated by HoopReplay"),36f,570f,paint)
            document.finishPage(page)
        }
        context.contentResolver.openOutputStream(uri,"w")!!.use(document::writeTo)
        return fileName
    }catch(error:Throwable){
        context.contentResolver.delete(uri,null,null)
        throw error
    }finally{document.close()}
}
