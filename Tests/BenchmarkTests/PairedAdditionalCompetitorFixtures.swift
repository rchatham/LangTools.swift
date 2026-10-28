import Foundation
#if canImport(MacPawOpenAI)
import MacPawOpenAI
#endif

// Keep conflicting OpenAI module/type names out of the LangTools fixture file.
extension PairedCompetitorBenchmarkTests {
    static func additionalEncodeVariants(count: Int) -> [PairedEncodeVariant] {
        var variants = [PairedEncodeVariant]()
        #if canImport(MacPawOpenAI)
        let macPawMessages: [MacPawOpenAI.ChatQuery.ChatCompletionMessageParam] = (0..<count).map {
            $0.isMultiple(of: 2)
                ? .user(.init(content: .string(text($0, count: count))))
                : .assistant(.init(content: .textContent(text($0, count: count))))
        }
        variants.append(.init("MacPawOpenAI", MacPawOpenAI.ChatQuery(messages: macPawMessages, model: MacPawOpenAI.Model.gpt4_o, stream: false)))
        #endif
        return variants
    }

    static func additionalDecodeVariants(data: Data) -> [PairedDecodeVariant] {
        var variants = [PairedDecodeVariant]()
        #if canImport(MacPawOpenAI)
        variants.append(.init("MacPawOpenAI", MacPawOpenAI.ChatResult.self, data: data))
        #endif
        return variants
    }
}
