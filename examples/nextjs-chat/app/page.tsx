'use client';

import { useChat } from '@ai-sdk/react';

export default function Chat() {
  const { messages, input, handleInputChange, handleSubmit, isLoading } = useChat();

  return (
    <div className="min-h-screen text-slate-100">
      <header className="border-b border-white/10">
        <div className="mx-auto max-w-4xl px-4 py-4">
          <h1 className="text-xl font-semibold tracking-tight">Fastpaca Chat Example</h1>
          <p className="text-sm text-slate-400">Using gpt-4o-mini (400k context window)</p>
        </div>
      </header>

      <main className="mx-auto max-w-4xl px-4 py-6">
        {messages.length === 0 && (
          <div className="text-center text-slate-400">
            <p className="mb-2 text-base font-medium">Start a conversation</p>
            <p className="text-sm">Fastpaca manages context on the backend</p>
          </div>
        )}

        <div className="flex flex-col gap-3">
          {messages.map((message) => (
            <div
              key={message.id}
              className={`flex ${message.role === 'user' ? 'justify-end' : 'justify-start'}`}
            >
              <div
                className={`max-w-[80%] rounded-xl px-4 py-2 shadow-md ${
                  message.role === 'user'
                    ? 'bg-blue-600 text-white'
                    : 'bg-white/5 ring-1 ring-white/10 backdrop-blur'
                }`}
              >
                {message.parts.map((part, i) => {
                  if (part.type === 'text') return <div key={i} className="whitespace-pre-wrap">{part.text}</div>;
                  return null;
                })}
              </div>
            </div>
          ))}

          {isLoading && (
            <div className="flex justify-start">
              <div className="max-w-[80%] rounded-xl bg-white/5 px-4 py-2 ring-1 ring-white/10">
                <div className="flex items-center gap-2">
                  <div className="h-2 w-2 animate-bounce rounded-full bg-slate-400" />
                  <div className="h-2 w-2 animate-bounce rounded-full bg-slate-400 [animation-delay:0.2s]" />
                  <div className="h-2 w-2 animate-bounce rounded-full bg-slate-400 [animation-delay:0.4s]" />
                </div>
              </div>
            </div>
          )}
        </div>
      </main>

      <footer className="sticky bottom-0 bg-slate-900/40 backdrop-blur border-t border-white/10">
        <div className="mx-auto max-w-4xl px-4 py-4">
          <form onSubmit={handleSubmit} className="flex gap-2">
            <input
              value={input}
              onChange={handleInputChange}
              placeholder="Type your message..."
              className="flex-1 rounded-xl border border-white/10 bg-white/5 px-4 py-2 text-slate-100 placeholder:text-slate-400 outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-500/30"
              disabled={isLoading}
            />
            <button
              type="submit"
              disabled={isLoading || !input.trim()}
              className="rounded-xl bg-blue-600 px-5 py-2 text-white shadow transition hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Send
            </button>
          </form>
        </div>
      </footer>
    </div>
  );
}
