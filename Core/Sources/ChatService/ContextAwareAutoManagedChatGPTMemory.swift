import Foundation
import OpenAIService

public final class ContextAwareAutoManagedChatGPTMemory: ChatGPTMemory {
    private let memory: AutoManagedChatGPTMemory
    let contextController: DynamicContextController
    let functionProvider: ChatFunctionProvider
    weak var chatService: ChatService?

    public var messages: [ChatMessage] {
        get async { await memory.messages }
    }

    public var remainingTokens: Int? {
        get async { await memory.remainingTokens }
    }
    
    public var history: [ChatMessage] {
        get async { await memory.history }
    }
    
    func observeHistoryChange(_ observer: @escaping () -> Void) {
        memory.observeHistoryChange(observer)
    }

    init(
        configuration: ChatGPTConfiguration,
        functionProvider: ChatFunctionProvider
    ) {
        memory = AutoManagedChatGPTMemory(
            systemPrompt: "",
            configuration: configuration,
            functionProvider: functionProvider
        )
        contextController = DynamicContextController(
            memory: memory,
            functionProvider: functionProvider,
            contextCollectors: allContextCollectors
        )
        self.functionProvider = functionProvider
    }

    public func mutateHistory(_ update: (inout [ChatMessage]) -> Void) async {
        await memory.mutateHistory(update)
    }

    public func refresh() async {
        let content = (await memory.history)
            .last(where: { $0.role == .user || $0.role == .function })?.content
        try? await contextController.updatePromptToMatchContent(systemPrompt: """
        \(chatService?.systemPrompt ?? "")
        \(chatService?.extraSystemPrompt ?? "")
        """, content: content ?? "")
        await memory.refresh()
    }
}

