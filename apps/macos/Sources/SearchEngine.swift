/**
 * 本地向量语义检索引擎 (PRD FR-09)
 *
 * 特性：
 *   1. 基于 macOS 原生 NaturalLanguage 框架（NLEmbedding），零模型体积、完全脱机、隐私安全
 *   2. 中英文分词与 300 维密集向量嵌入（空间隔离，避免多语言向量杂糅）
 *   3. 混合搜索（Hybrid Search）：关键词稀疏匹配 + 向量密集余弦相似度
 *   4. 段落向量预计算与内存常驻，彻底消除按键时的实时 NLP 重复推断与全库磁盘读取
 *   5. 全异步检索接口，杜绝阻塞主线程
 */

import Foundation
import NaturalLanguage

struct SearchEngineResult {
    let id: String
    let title: String
    let snippet: String
    let score: Double
    let matchedText: String
    let updatedAt: Double
}

final class SearchEngine {
    static let shared = SearchEngine()

    private let zhEmbedding = NLEmbedding.wordEmbedding(for: .simplifiedChinese)
    private let enEmbedding = NLEmbedding.wordEmbedding(for: .english)

    // 内存向量缓存：noteId -> 文档平均向量
    private var vectorCache = [String: [Double]]()
    // 文档段落及预计算向量缓存：noteId -> [(段落文本, 预计算向量)]
    private var paragraphCache = [String: [(text: String, vector: [Double]?)]]()
    // 文档内容纯文本小写缓存，避免检索时全库反复磁盘 IO
    private var contentCache = [String: String]()

    // 专属工作队列
    private let queue = DispatchQueue(label: "app.ifolo.searchengine", qos: .userInitiated)

    private init() {}

    /// 初始化全量索引
    func warmup(notes: [NoteMeta]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            Log.write("语义检索引擎开始预热索引，共 \(notes.count) 篇笔记")
            for note in notes {
                let markdown = Store.shared.read(id: note.id)
                self.indexInternal(id: note.id, markdown: markdown)
            }
            Log.write("语义检索引擎索引就绪，已构建 \(self.vectorCache.count) 条笔记向量")
        }
    }

    /// 增量更新单篇笔记索引
    func indexNote(id: String, content: String) {
        queue.async { [weak self] in
            self?.indexInternal(id: id, markdown: content)
        }
    }

    /// 移除笔记索引
    func removeNote(id: String) {
        queue.async { [weak self] in
            self?.vectorCache.removeValue(forKey: id)
            self?.paragraphCache.removeValue(forKey: id)
            self?.contentCache.removeValue(forKey: id)
        }
    }

    private func indexInternal(id: String, markdown: String) {
        contentCache[id] = markdown.lowercased()

        let rawParagraphs = markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 预计算各段落的向量并缓存，检索时仅需点积计算，不再重复调用分词与嵌入模型
        var paraWithVectors: [(text: String, vector: [Double]?)] = []
        for p in rawParagraphs {
            let vec = computeTextVector(p)
            paraWithVectors.append((text: p, vector: vec))
        }
        paragraphCache[id] = paraWithVectors

        if let docVector = computeTextVector(markdown) {
            vectorCache[id] = docVector
        }
    }

    /// 异步执行混合语义检索（推荐，不阻塞主线程）
    func search(query: String, limit: Int = 20, completion: @escaping ([SearchEngineResult]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            completion([])
            return
        }

        queue.async { [weak self] in
            guard let self = self else {
                completion([])
                return
            }
            let results = self.performSearch(query: trimmed, limit: limit)
            completion(results)
        }
    }

    /// 同步版本检索（供测试或特定同步调用）
    func searchSync(query: String, limit: Int = 20) -> [SearchEngineResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        return queue.sync {
            self.performSearch(query: trimmed, limit: limit)
        }
    }

    private func performSearch(query: String, limit: Int) -> [SearchEngineResult] {
        let notes = Store.shared.listNotes()
        if notes.isEmpty { return [] }

        let queryVector = computeTextVector(query)
        let lowerQuery = query.lowercased()
        let queryKeywords = tokenize(query)

        var scoredResults = [(note: NoteMeta, score: Double, matchedText: String)]()

        for note in notes {
            let noteId = note.id
            let paragraphs = paragraphCache[noteId] ?? []
            let docVector = vectorCache[noteId]

            // 1. 语义相似度得分 (0.0 ~ 1.0)
            var semanticScore = 0.0
            if let qv = queryVector, let dv = docVector {
                semanticScore = max(0.0, cosineSimilarity(qv, dv))
            }

            // 2. 关键词匹配得分 (0.0 ~ 1.0)
            // 优先使用内存小写缓存，避免磁盘 IO
            let noteContent = contentCache[noteId] ?? Store.shared.read(id: noteId).lowercased()
            var keywordScore = 0.0
            var matchCount = 0

            if note.title.lowercased().contains(lowerQuery) {
                keywordScore += 0.5
            }
            if noteContent.contains(lowerQuery) {
                keywordScore += 0.4
            }

            for kw in queryKeywords {
                if noteContent.contains(kw.lowercased()) {
                    matchCount += 1
                }
            }
            if !queryKeywords.isEmpty {
                keywordScore += 0.3 * (Double(matchCount) / Double(queryKeywords.count))
            }
            keywordScore = min(1.0, keywordScore)

            // 3. 混合打分：有向量时加权，无向量时纯关键词
            var finalScore = 0.0
            if queryVector != nil && docVector != nil {
                finalScore = (keywordScore * 0.45) + (semanticScore * 0.55)
            } else {
                finalScore = keywordScore
            }

            // 4. 提取最佳命中段落（直接复用段落预计算向量，无需再次模型推理）
            var bestParagraph = note.snippet.isEmpty ? (paragraphs.first?.text ?? "空白笔记") : note.snippet
            var bestParaScore = 0.0

            for paraItem in paragraphs {
                let lowerPara = paraItem.text.lowercased()
                var paraScore = 0.0
                if lowerPara.contains(lowerQuery) {
                    paraScore += 0.6
                }
                if let qv = queryVector, let pv = paraItem.vector {
                    let sim = cosineSimilarity(qv, pv)
                    paraScore += max(0, sim * 0.4)
                }
                if paraScore > bestParaScore {
                    bestParaScore = paraScore
                    bestParagraph = paraItem.text
                }
            }

            // 过滤阈值（大于 0.25 视为相关）
            if finalScore >= 0.25 || (keywordScore > 0.1) {
                scoredResults.append((note, finalScore, bestParagraph))
            }
        }

        // 按得分降序排序并截取 limit
        scoredResults.sort { $0.score > $1.score }
        let topItems = scoredResults.prefix(limit)

        return topItems.map { item in
            SearchEngineResult(
                id: item.note.id,
                title: item.note.title,
                snippet: item.note.snippet,
                score: item.score,
                matchedText: item.matchedText,
                updatedAt: item.note.updatedAt
            )
        }
    }

    // MARK: - 内部数学与 NLP 计算

    /// 将文本转化为高维向量（同语言空间下的词向量平均）
    private func computeTextVector(_ text: String) -> [Double]? {
        let tokens = tokenize(text)
        if tokens.isEmpty { return nil }

        // 检测文本语言倾向，避免跨模型向量空间混杂
        let isChineseDominant = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
        let embedding = isChineseDominant ? (zhEmbedding ?? enEmbedding) : (enEmbedding ?? zhEmbedding)
        guard let activeEmbedding = embedding else { return nil }

        var vectors = [[Double]]()
        for token in tokens {
            if let v = activeEmbedding.vector(for: token) {
                vectors.append(v)
            }
        }

        if vectors.isEmpty { return nil }
        let dim = vectors[0].count
        var mean = [Double](repeating: 0, count: dim)

        for v in vectors {
            for i in 0..<dim {
                mean[i] += v[i]
            }
        }

        let total = Double(vectors.count)
        for i in 0..<dim {
            mean[i] /= total
        }

        return mean
    }

    /// 余弦相似度
    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count && !a.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0

        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        if normA == 0 || normB == 0 { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }

    /// 分词：保留有意义的 CJK 单字词，不截断
    private func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens = [String]()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                // 如果是中文单个字符或长度大于1的英文单词，均作为有效 Token
                let isCJK = word.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                if isCJK || word.count > 1 {
                    tokens.append(word)
                }
            }
            return true
        }
        return tokens
    }
}
