import Foundation

// MARK: - OpenAI 兼容客户端

final class OpenAICompatibleAIClient: AIServicing {
    private let session: URLSession
    /// 解析无时区标注的时间（如 "2026-06-01 08:00"）时使用的时区。
    private let timeZone: TimeZone

    init(session: URLSession = .shared, timeZone: TimeZone = .current) {
        self.session = session
        self.timeZone = timeZone
    }

    func extractTodos(from text: String, now: Date, config: AIConfig, apiKey: String) async throws -> [ParsedTodo] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TodoServiceError.notConfigured("API Key 未填写") }

        guard let url = config.chatCompletionsURL(),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { throw TodoServiceError.notConfigured("接口地址无效：\(config.baseURL)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(ChatRequest(
                model: config.model,
                messages: [
                    .init(role: "system", content: AIPrompts.extractionSystemPrompt(now: now, timeZone: timeZone)),
                    .init(role: "user", content: text),
                ],
                temperature: 0,
                stream: false,
                responseFormat: .init(type: "json_object")
            ))
        } catch {
            throw TodoServiceError.decode("请求体编码失败：\(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TodoServiceError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TodoServiceError.network("响应不是 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TodoServiceError.network("HTTP \(http.statusCode) \(bodySnippet(data))")
        }

        let envelope: ChatResponse
        do {
            envelope = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw TodoServiceError.decode("响应不是 chat/completions 结构：\(error.localizedDescription)")
        }
        guard let content = envelope.choices.first?.message?.content else {
            throw TodoServiceError.decode("响应缺少 choices[0].message.content")
        }
        return try parseTodos(from: content)
    }

    /// 解析模型返回的 content：先剥代码围栏，再解 {"todos":[…]}。
    /// 单条 deadline 解析失败只置 nil，不丢弃整条待办；title 为空的条目丢弃。
    /// GET <base>/models：既取可用模型，也当连通性探测。
    func listModels(config: AIConfig, apiKey: String) async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TodoServiceError.notConfigured("API Key 未填写")
        }
        guard let url = config.modelsURL() else {
            throw TodoServiceError.notConfigured("接口地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(config.timeout, 30)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TodoServiceError.network("无 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw TodoServiceError.network("HTTP \(http.statusCode) \(body)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw TodoServiceError.decode("响应里没有 data 数组")
        }
        let ids = list.compactMap { $0["id"] as? String }.sorted()
        guard !ids.isEmpty else { throw TodoServiceError.decode("模型列表为空") }
        return ids
    }

    func parseTodos(from content: String) throws -> [ParsedTodo] {
        let json = strippingCodeFence(content)
        guard let data = json.data(using: .utf8) else {
            throw TodoServiceError.decode("模型输出无法编码为 UTF-8")
        }
        let payload: TodosPayload
        do {
            payload = try JSONDecoder().decode(TodosPayload.self, from: data)
        } catch {
            throw TodoServiceError.decode("模型输出不是合法 JSON：\(error.localizedDescription)")
        }
        return payload.todos.compactMap { raw in
            let title = (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let deadline = raw.deadline.flatMap { parseDeadline($0) }
            return ParsedTodo(title: title, deadline: deadline, note: (raw.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func parseDeadline(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// 模型偶尔仍会包一层 ```json 围栏（前面还可能有客套话），这里取出围栏内的正文。
    private func strippingCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.range(of: "```") else { return trimmed }
        var body = String(trimmed[open.upperBound...])
        while let first = body.first, first.isLetter { body.removeFirst() } // 语言标记 json
        if let close = body.range(of: "```") { body = String(body[..<close.lowerBound]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bodySnippet(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return "<空响应体>" }
        return String(text.prefix(200))
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case responseFormat = "response_format"
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
    }
    let choices: [Choice]
}

private struct TodosPayload: Decodable {
    struct Item: Decodable {
        let title: String?
        let note: String?
        let deadline: String?

        enum CodingKeys: String, CodingKey { case title, note, deadline }

        // 逐字段宽松解码：某个字段类型不对时只丢该字段，不连累整组待办。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            note = try? container.decodeIfPresent(String.self, forKey: .note)
            deadline = try? container.decodeIfPresent(String.self, forKey: .deadline)
        }
    }
    let todos: [Item]
}

// MARK: - 本地兜底解析器

/// 不联网的解析器：用正则识别时间表达并换算成绝对时间，供"没填 Key 也能用"的场景。
final class MockAIService: AIServicing {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func extractTodos(from text: String, now: Date, config: AIConfig, apiKey: String) async throws -> [ParsedTodo] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let todayStart = calendar.startOfDay(for: now)

        var results: [ParsedTodo] = []
        for segment in splitSegments(text) {
            let work = NSMutableString(string: normalizeChineseNumerals(segment))
            var day: Date?
            if day == nil { day = takeAbsoluteDate(work, calendar: calendar, now: now, todayStart: todayStart) }
            if day == nil { day = takeWeekday(work, calendar: calendar, todayStart: todayStart) }
            if day == nil { day = takeRelativeDay(work, calendar: calendar, todayStart: todayStart) }

            // 时间段（如「一点半到三点」）取开始时刻
            var note = ""
            var time: (hour: Int, minute: Int)?
            if let range = takeTimeRange(work) {
                time = (range.hour, range.minute)
                note = range.raw
            } else {
                time = takeTimeOfDay(work)
            }

            var deadline: Date?
            if let day {
                deadline = calendar.date(byAdding: DateComponents(hour: time?.hour ?? 0, minute: time?.minute ?? 0), to: day)
            } else if let time {
                var candidate = calendar.date(byAdding: DateComponents(hour: time.hour, minute: time.minute), to: todayStart)
                // 只给了时刻且已经过去，按"明天这个点"理解
                if let value = candidate, value < now {
                    candidate = calendar.date(byAdding: .day, value: 1, to: value)
                }
                deadline = candidate
            }

            let title = cleanTitle(NSMutableString(string: scrubResidualTime(work as String)))
            guard !title.isEmpty else { continue }
            results.append(ParsedTodo(title: title, deadline: deadline, note: note))
        }
        return results
    }

    // MARK: 切分

    private func splitSegments(_ text: String) -> [String] {
        var segments: [String] = []
        for line in text.components(separatedBy: .newlines) {
            for piece in line.components(separatedBy: CharacterSet(charactersIn: "；;")) {
                var trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                // 去掉列表符号，但不动开头的数字（"9月10日" 的 9 属于日期）
                while let first = trimmed.first, "-*•·".contains(first) {
                    trimmed.removeFirst()
                    trimmed = trimmed.trimmingCharacters(in: .whitespaces)
                }
                if !trimmed.isEmpty { segments.append(trimmed) }
            }
        }
        return segments
    }

    // MARK: 日期

    private func takeAbsoluteDate(_ work: NSMutableString, calendar: Calendar, now: Date, todayStart: Date) -> Date? {
        let patterns: [(pattern: String, hasYear: Bool)] = [
            ("(\\d{4})-(\\d{1,2})-(\\d{1,2})", true),
            ("(\\d{4})年(\\d{1,2})月(\\d{1,2})[日号]?", true),
            ("(\\d{1,2})月(\\d{1,2})[日号]", false),
        ]
        for entry in patterns {
            guard let hit = firstHit(entry.pattern, in: work) else { continue }
            let numbers = hit.groups.compactMap { $0.flatMap(Int.init) }
            guard numbers.count == hit.groups.count else { continue }
            let year: Int
            let month: Int
            let dayOfMonth: Int
            if entry.hasYear {
                year = numbers[0]; month = numbers[1]; dayOfMonth = numbers[2]
            } else {
                month = numbers[0]; dayOfMonth = numbers[1]
                year = calendar.component(.year, from: now)
            }
            guard var date = makeDate(year: year, month: month, day: dayOfMonth, calendar: calendar) else { continue }
            delete(hit, from: work)
            // 只给月日且已过去：理解为明年
            if !entry.hasYear, date < todayStart,
               let next = calendar.date(byAdding: .year, value: 1, to: date) {
                date = next
            }
            return date
        }
        return nil
    }

    private func takeWeekday(_ work: NSMutableString, calendar: Calendar, todayStart: Date) -> Date? {
        guard let hit = firstHit("(下下|下|这|本)?\\s*(?:周|星期|礼拜)\\s*([一二三四五六日天])", in: work),
              let target = weekdayNumber(hit.groups[1]) else { return nil }
        let todayWeekday = isoWeekday(todayStart, calendar: calendar)
        let prefix = hit.groups[0] ?? ""
        var date: Date?
        switch prefix {
        case "下", "下下":
            let offsetToWeekStart = -(todayWeekday - 1)
            guard let weekStart = calendar.date(byAdding: .day, value: offsetToWeekStart, to: todayStart) else { return nil }
            let weeksForward = prefix == "下下" ? 14 : 7
            date = calendar.date(byAdding: .day, value: weeksForward + (target - 1), to: weekStart)
        default:
            let delta = (target - todayWeekday + 7) % 7
            date = calendar.date(byAdding: .day, value: delta, to: todayStart)
        }
        guard let result = date else { return nil }
        delete(hit, from: work)
        return result
    }

    private func takeRelativeDay(_ work: NSMutableString, calendar: Calendar, todayStart: Date) -> Date? {
        guard let hit = firstHit("(大后天|后天|明天|今天)", in: work),
              let word = hit.groups[0] else { return nil }
        let delta: Int
        switch word {
        case "大后天": delta = 3
        case "后天": delta = 2
        case "明天": delta = 1
        default: delta = 0
        }
        guard let date = calendar.date(byAdding: .day, value: delta, to: todayStart) else { return nil }
        delete(hit, from: work)
        return date
    }

    // MARK: 时间段

    /// 「A 到 B」型时间段：取开始时刻作为截止时间，原文进 note。
    private func takeTimeRange(_ work: NSMutableString) -> (hour: Int, minute: Int, raw: String)? {
        let atom = "(?:上午|下午|晚上|早上|凌晨|中午|傍晚|夜里)?\\s*\\d{1,2}\\s*(?:点\\s*(?:半|一刻|三刻|\\d{1,2}\\s*分)?|[:：]\\s*\\d{1,2})"

        // 时间词落在段尾会先被 takeTimeOfDay 拿走，所以先在这里整体吞掉
        if let hit = firstHit("(\(atom))\\s*(?:到|至|-|~|—|–)\\s*\(atom)", in: work) {
            let first = hit.groups[0] ?? ""
            delete(hit, from: work)
            let scratch = NSMutableString(string: first)
            if let start = takeTimeOfDay(scratch) {
                return (start.hour, start.minute, first)
            }
            return nil
        }

        // 起点只写了「上午/下午」：「下午到三点」
        if let hit = firstHit("(上午|下午|晚上|早上|凌晨|中午|傍晚|夜里)\\s*(?:到|至)\\s*\(atom)", in: work),
           let word = hit.groups[0],
           let start = defaultTime(for: word) {
            delete(hit, from: work)
            return (start.hour, start.minute, word)
        }

        return nil
    }

    // MARK: 中文数字

    /// 把「十点」「一点半」「十分钟」里的中文数字换成阿拉伯数字，后面的正则只管数字。
    private func normalizeChineseNumerals(_ text: String) -> String {
        var result = text
        result = replaceChineseNumbers(in: result, before: ["点", "时", ":", "："])
        result = replaceChineseNumbers(in: result, before: ["分"])
        return result
    }

    private func replaceChineseNumbers(in text: String, before suffixes: [String]) -> String {
        let suffix = suffixes.joined(separator: "|")
        let pattern = "([一二三四五六七八九十两]{1,3})(?=\\s*(?:\(suffix)))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let group = match.range(at: 1)
            guard let swiftRange = Range(group, in: text),
                  let value = chineseNumber(String(text[swiftRange])) else { continue }
            ns.replaceCharacters(in: group, with: String(value))
        }
        return ns as String
    }

    private func chineseNumber(_ text: String) -> Int? {
        if text == "两" { return 2 }
        if let direct = chineseDigit(text) { return direct }
        guard text.contains("十") else { return nil }
        let parts = text.split(separator: "十", omittingEmptySubsequences: false)
        let tens = parts.first.flatMap { $0.isEmpty ? 1 : chineseDigit(String($0)) } ?? 1
        let ones = parts.count > 1 ? (parts[1].isEmpty ? 0 : chineseDigit(String(parts[1])) ?? 0) : 0
        return tens * 10 + ones
    }

    private func chineseDigit(_ text: String) -> Int? {
        switch text {
        case "零": return 0
        case "一": return 1
        case "二": return 2
        case "两": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "七": return 7
        case "八": return 8
        case "九": return 9
        case "十": return 10
        default: return nil
        }
    }

    /// 兜底：解析过的文字里若还残留时间词，别让它进标题。
    private func scrubResidualTime(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: "(?:上午|下午|晚上|早上|凌晨|中午|傍晚|夜里)\\s*(?:到|至)?\\s*", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "\\d{1,2}\\s*(?:点|时)\\s*(?:半|一刻|三刻|\\d{1,2}\\s*分)?\\s*(?:到|至)?", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "\\d{1,2}\\s*[:：]\\s*\\d{1,2}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "^(?:到|至|~|-|—|–)\\s*", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "^(?:到|至|~|-|—|–)\\s*", with: "", options: .regularExpression)
        return result
    }

    // MARK: 时刻

    private func takeTimeOfDay(_ work: NSMutableString) -> (hour: Int, minute: Int)? {
        let period = "(上午|下午|晚上|早上|凌晨|中午|傍晚|夜里)"

        if let hit = firstHit(period + "?\\s*(\\d{1,2})\\s*[:：]\\s*(\\d{1,2})", in: work),
           let hour = hit.groups[1].flatMap(Int.init), let minute = hit.groups[2].flatMap(Int.init),
           let value = makeTime(hour: hour, minute: minute, period: hit.groups[0]) {
            delete(hit, from: work)
            return value
        }
        if let hit = firstHit(period + "?\\s*(\\d{1,2})\\s*点半", in: work),
           let hour = hit.groups[1].flatMap(Int.init),
           let value = makeTime(hour: hour, minute: 30, period: hit.groups[0]) {
            delete(hit, from: work)
            return value
        }
        // "10点" / "10点半" / "10点30分"
        if let hit = firstHit(period + "?\\s*(\\d{1,2})\\s*点\\s*(半|(\\d{1,2})\\s*分)?", in: work),
           let hour = hit.groups[1].flatMap(Int.init) {
            let minute: Int
            if hit.groups[2] == "半" {
                minute = 30
            } else {
                minute = hit.groups[3].flatMap(Int.init) ?? 0
            }
            if let value = makeTime(hour: hour, minute: minute, period: hit.groups[0]) {
                delete(hit, from: work)
                return value
            }
        }
        // 只有"上午/下午/晚上"，用默认时刻
        if let hit = firstHit(period, in: work), let word = hit.groups[0], let value = defaultTime(for: word) {
            delete(hit, from: work)
            return value
        }
        return nil
    }

    private func makeTime(hour: Int, minute: Int, period: String?) -> (hour: Int, minute: Int)? {
        guard minute >= 0, minute <= 59 else { return nil }
        var adjusted = hour
        switch period {
        case "下午", "傍晚", "晚上", "夜里":
            if adjusted < 12 { adjusted += 12 }
        case "中午":
            if adjusted < 11 { adjusted += 12 }
        case "凌晨":
            if adjusted == 12 { adjusted = 0 }
        case "上午", "早上":
            break
        default:
            // 只说「三点」通常指 15:00，不会是凌晨 3 点
            if (1...5).contains(adjusted) { adjusted += 12 }
        }
        guard adjusted >= 0, adjusted <= 23 else { return nil }
        return (adjusted, minute)
    }

    private func defaultTime(for period: String) -> (hour: Int, minute: Int)? {
        switch period {
        case "上午", "早上": return (9, 0)
        case "中午": return (12, 0)
        case "下午": return (15, 0)
        case "傍晚": return (18, 0)
        case "晚上", "夜里": return (20, 0)
        case "凌晨": return (6, 0)
        default: return nil
        }
    }

    // MARK: 工具

    private func cleanTitle(_ work: NSMutableString) -> String {
        var text = work as String
        text = text.replacingOccurrences(of: "之前", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "以前", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "截止", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*前\\s*$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "^[\\s，,、。；;：:]+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[\\s，,、。；;：:]+$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        // Calendar 会把 2月30日 顺延到 3月2日，这里回读校验，避免编造日期
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    private func isoWeekday(_ date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date) // 1=周日 … 7=周六
        return weekday == 1 ? 7 : weekday - 1
    }

    private func weekdayNumber(_ text: String?) -> Int? {
        switch text {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日", "天": return 7
        default: return nil
        }
    }

    private struct RegexHit {
        var groups: [String?]
        var range: NSRange
    }

    private func firstHit(_ pattern: String, in text: NSMutableString) -> RegexHit? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(location: 0, length: text.length)
        guard let match = regex.firstMatch(in: text as String, range: full) else { return nil }
        var groups: [String?] = []
        // 0 号是整段匹配，调用方只关心捕获组
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            groups.append(range.location == NSNotFound ? nil : text.substring(with: range))
        }
        return RegexHit(groups: groups, range: match.range)
    }

    private func delete(_ hit: RegexHit, from text: NSMutableString) {
        guard hit.range.location != NSNotFound else { return }
        text.deleteCharacters(in: hit.range)
        // 时间词紧跟着「前/之前/以内」时一并吞掉，避免残留在标题开头
        let location = hit.range.location
        for suffix in ["之前", "以前", "以内", "前"] as [NSString] {
            guard location + suffix.length <= text.length else { continue }
            let slice = NSRange(location: location, length: suffix.length)
            if text.substring(with: slice) == suffix as String {
                text.deleteCharacters(in: slice)
                break
            }
        }
    }
}
