// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 系统语言或应用内设定决定文案。服务器资源名称和路径始终保留原文。
func appText(_ key: String) -> String {
    let setting = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system"
    return localizedAppText(key, languageTag: appLanguageTag(for: setting))
}

/// 将应用的「跟随系统」选项解析为实际使用的语言。
func appLanguageTag(for setting: String) -> String {
    setting == "system" ? (Locale.preferredLanguages.first ?? "zh-Hans") : setting
}

/// 依据指定语言标记读取应用资源，繁中缺少专用词条时转换简中文案。
func localizedAppText(_ key: String, languageTag preferred: String) -> String {
    let locale = Locale(identifier: preferred)
    let language: String
    if locale.language.languageCode?.identifier == "zh" {
        let script = locale.language.script?.identifier
        let traditional = script.map { $0 == "Hant" }
            ?? ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "")
        language = traditional ? "zh-Hant" : "zh-Hans"
    } else {
        language = "en"
    }

    #if SWIFT_PACKAGE
    let resources = Bundle.module
    #else
    let resources = Bundle.main
    #endif
    if let path = resources.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
        let result = bundle.localizedString(forKey: key, value: key, table: nil)
        if result != key { return result }
    }
    if language == "zh-Hant" {
        return key.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? key
    }
    return key
}
