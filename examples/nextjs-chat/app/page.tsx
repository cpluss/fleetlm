'use client';

import { useChat } from '@ai-sdk/react';

export default function Chat() {
  const { messages, input, handleInputChange, handleSubmit, isLoading } = useChat();

  return (
    <div className="flex min-h-screen flex-col">
      {/* Header */}
      <header className="border-b border-gray-200 bg-white px-4 py-3">
        <div className="mx-auto max-w-3xl">
          <h1 className="text-xl font-semibold">Fastpaca Chat Example</h1>
          <p className="text-sm text-gray-500">
            Using gpt-4o-mini (400k context window)
          </p>
        </div>
      </header>

      {/* Messages */}
      <main className="flex-1 overflow-y-auto bg-gray-50 px-4 py-6">
        <div className="mx-auto max-w-3xl space-y-4">
          {messages.length === 0 && (
            <div className="text-center text-gray-500">
              <p className="mb-2 text-lg font-medium">Start a conversation</p>
              <p className="text-sm">
                Fastpaca manages context on the backend
              </p>
            </div>
          )}

          {messages.map(message => (
            <div
              key={message.id}
              className={`flex ${
                message.role === 'user' ? 'justify-end' : 'justify-start'
              }`}
            >
              <div
                className={`max-w-[80%] rounded-lg px-4 py-2 ${
                  message.role === 'user'
                    ? 'bg-blue-600 text-white'
                    : 'bg-white text-gray-900 shadow-sm'
                }`}
              >
                {message.parts.map((part, i) => {
                  if (part.type === 'text') {
                    return (
                      <div key={i} className="whitespace-pre-wrap">
                        {part.text}
                      </div>
                    );
                  }
                  return null;
                })}
              </div>
            </div>
          ))}

          {isLoading && (
            <div className="flex justify-start">
              <div className="max-w-[80%] rounded-lg bg-white px-4 py-2 shadow-sm">
                <div className="flex items-center space-x-2">
                  <div className="h-2 w-2 animate-bounce rounded-full bg-gray-400"></div>
                  <div className="h-2 w-2 animate-bounce rounded-full bg-gray-400 [animation-delay:0.2s]"></div>
                  <div className="h-2 w-2 animate-bounce rounded-full bg-gray-400 [animation-delay:0.4s]"></div>
                </div>
              </div>
            </div>
          )}
        </div>
      </main>

      {/* Input */}
      <footer className="border-t border-gray-200 bg-white px-4 py-4">
        <form onSubmit={handleSubmit} className="mx-auto max-w-3xl">
          <div className="flex space-x-2">
            <input
              value={input}
              onChange={handleInputChange}
              placeholder="Type your message..."
              className="flex-1 rounded-lg border border-gray-300 px-4 py-2 focus:border-blue-500 focus:outline-none"
              disabled={isLoading}
            />
            <button
              type="submit"
              disabled={isLoading || !input.trim()}
              className="rounded-lg bg-blue-600 px-6 py-2 text-white hover:bg-blue-700 disabled:bg-gray-300 disabled:cursor-not-allowed"
            >
              Send
            </button>
          </div>
        </form>
      </footer>
    </div>
  );
}
