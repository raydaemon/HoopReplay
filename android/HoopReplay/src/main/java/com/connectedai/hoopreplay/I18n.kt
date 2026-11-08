package com.connectedai.hoopreplay

import android.content.Context
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.Locale

/** Interface languages, in menu order; codes and native names match the Web and iOS apps. */
enum class AppLanguage(val code:String, val nativeName:String) {
    English("en","English"), ChineseSimplified("zh-Hans","简体中文"), ChineseTraditional("zh-Hant","繁體中文"),
    Spanish("es","Español"), French("fr","Français"), German("de","Deutsch"), Portuguese("pt","Português"),
    Japanese("ja","日本語"), Korean("ko","한국어"), Italian("it","Italiano");

    companion object {
        /** The shipped language a BCP 47 tag or saved code maps to, or null when we do not ship it. */
        fun match(tag:String?):AppLanguage? {
            val lower=tag?.lowercase()?.takeIf{it.isNotBlank()}?:return null
            if(lower.startsWith("zh"))return if(Regex("hant|tw|hk|mo").containsMatchIn(lower))ChineseTraditional else ChineseSimplified
            val primary=lower.split('-','_')[0]
            return entries.firstOrNull{it.code==primary}
        }
    }
}

/**
 * Interface language for the Android app. The dictionary for the chosen language comes from
 * assets/i18n/<code>.json (copied from web/i18n at build time) and [t] looks every UI string up by
 * its English text. Reading [t] inside a composable subscribes it to language changes.
 */
object I18n {
    const val KEY="language"
    private val state=mutableStateOf(AppLanguage.English)
    @Volatile private var dict:Map<String,String> = emptyMap()
    private var started=false
    val language:AppLanguage get()=state.value

    /** Saved choice, then the device language. Safe to call more than once. */
    fun start(context:Context){
        if(started)return
        started=true
        val saved=context.getSharedPreferences("hoopreplay",Context.MODE_PRIVATE).getString(KEY,null)
        apply(context,AppLanguage.match(saved)?:AppLanguage.match(Locale.getDefault().toLanguageTag())?:AppLanguage.English)
    }

    /** The user picked a language: keep it locally and, when signed in, on the account so other devices follow. */
    fun set(context:Context,language:AppLanguage){
        save(context,language)
        apply(context,language)
        if(HoopSync.isSignedIn(context))CoroutineScope(Dispatchers.IO).launch{ runCatching{ HoopSync.updateLanguage(context,language.code) } }
    }

    /** A session arrived carrying the account's language: it wins over the device's. */
    fun adoptFromAccount(context:Context,code:String?){
        val language=AppLanguage.match(code)?:return
        if(language==state.value)return
        save(context,language)
        apply(context,language)
    }

    private fun save(context:Context,language:AppLanguage)=context.getSharedPreferences("hoopreplay",Context.MODE_PRIVATE).edit().putString(KEY,language.code).apply()

    private fun apply(context:Context,language:AppLanguage){
        dict=if(language==AppLanguage.English)emptyMap() else runCatching{
            val json=JSONObject(context.assets.open("i18n/${language.code}.json").bufferedReader().readText())
            json.keys().asSequence().associateWith{json.getString(it)}
        }.getOrDefault(emptyMap())
        state.value=language
    }

    /** `t("Sign out")` → the current language's text, or the English key; `{name}` placeholders come from [vars]. */
    fun t(key:String,vararg vars:Pair<String,Any?>):String{
        state.value
        val template=dict[key]?:key
        if(vars.isEmpty())return template
        return Regex("\\{(\\w+)\\}").replace(template){match->vars.firstOrNull{it.first==match.groupValues[1]}?.second?.toString()?:match.value}
    }
}

fun t(key:String,vararg vars:Pair<String,Any?>)=I18n.t(key,*vars)
