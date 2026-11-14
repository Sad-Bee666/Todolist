import Foundation

/// 待办抽取用的提示词。纯函数：当前时间与时区由调用方注入，便于测试与复现。
enum AIPrompts {
    private static let weekdayNames = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    static func extractionSystemPrompt(now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let weekday = weekdayNames[max(0, min(6, calendar.component(.weekday, from: now) - 1))]
        let offset = offsetText(timeZone.secondsFromGMT(for: now))
        let minuteStamp = formatDate(now, "yyyy-MM-dd HH:mm", timeZone: timeZone)
        let isoNow = isoText(now, timeZone: timeZone)

        // 示例里的绝对时间从 now 推算，避免示例与"当前时间"互相矛盾。
        let tomorrowStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        let tomorrowAfternoon = calendar.date(byAdding: DateComponents(hour: 15), to: tomorrowStart) ?? tomorrowStart
        let tomorrowISO = isoText(tomorrowAfternoon, timeZone: timeZone)

        return """
        你是一个待办事项抽取器。你的唯一任务：把用户给出的自然语言文本拆成结构化待办，并且只输出 JSON。

        # 当前上下文
        - 当前日期时间：\(minuteStamp)（\(weekday)）
        - 时区：\(timeZone.identifier)（UTC\(offset)）
        - 当前时间的 ISO8601 表示：\(isoNow)
        以上上下文是换算相对时间的唯一基准，请以它为准，不要假设今天是别的日期。

        # 时间换算（必须做）
        原文出现"明天 8 点""下周三""月底前""三天后"这类相对时间表达时，必须以上面的当前日期时间为基准换算成绝对时间，禁止把相对时间原样留在输出里。
        - "今天""明天""后天""大后天"按当前日期加减对应天数。
        - "周X""下周X""星期X"按当前日期推算到对应的那一天（同一年、同一时区）。
        - "月底前"取当前月最后一天 23:59；"年初""季度末"等同样换算成具体某天。
        - 只说了日期没说时刻：取该日 00:00；只说了"上午/下午/晚上"没说具体时间：分别取 09:00 / 15:00 / 20:00。
        - 换算结果应落在当前时间之后，除非原文明确指向过去（如"去年""上个月"）。

        # 字段规则
        - title：必填。保留原文关键信息（做什么、对谁、在哪），去掉时间词与语气词，不编造原文没有的内容，也不要翻译或改写原文用词。
        - deadline：原文有明确时间指向时才填，格式为带时区偏移的 ISO8601，例如 \(isoNow)；如果原文完全没有时间指向，必须填 null，不要猜、不要拿当前时间凑。
        - note：放不进 title 的补充信息（备注、要求、关联事项），没有就用空字符串 ""。
        - 一条待办一个对象；一句话里有多件互相独立的事就拆成多个对象。

        # 输出契约（严格遵守）
        - 只输出一个 JSON 对象，形如 {"todos":[{"title":"...","deadline":"2026-01-02T20:00:00+08:00","note":""}]}
        - 顶层只有一个键 todos，值为数组；没有待办时输出 {"todos":[]}
        - 不要输出 markdown 代码块围栏（不要出现 ```json），不要任何解释、前缀或后缀。
        - 键与字符串一律用双引号，输出必须能被标准 JSON 解析器直接解析。

        # 示例

        示例 1（含相对时间，需要换算）
        输入：明天下午 3 点前把周报发给张总
        输出：{"todos":[{"title":"把周报发给张总","deadline":"\(tomorrowISO)","note":"下午 3 点前发出"}]}

        示例 2（不含任何时间）
        输入：给妈妈打电话，顺便问她血压药吃完没
        输出：{"todos":[{"title":"给妈妈打电话","deadline":null,"note":"顺便问她血压药吃完没"}]}
        """
    }

    private static func formatDate(_ date: Date, _ format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// "2026-01-02T20:00:00+08:00"
    private static func isoText(_ date: Date, timeZone: TimeZone) -> String {
        formatDate(date, "yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone) + offsetText(timeZone.secondsFromGMT(for: date))
    }

    /// "+08:00" / "-03:30"
    private static func offsetText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = abs(seconds % 3600) / 60
        return String(format: "%+03d:%02d", hours, minutes)
    }
}
