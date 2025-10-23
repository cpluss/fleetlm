import { ChatApp } from "@/components/chat-app";

const config = {
  wsUrl: process.env.NEXT_PUBLIC_FLEETLM_WS_URL ?? "ws://localhost:4000/socket",
  agentId: process.env.NEXT_PUBLIC_FLEETLM_AGENT_ID ?? "nextjs-demo-agent",
  userId: process.env.NEXT_PUBLIC_FLEETLM_USER_ID ?? "nextjs-demo-user"
};

export default function Home() {
  return (
    <main
      style={{
        width: "100%",
        maxWidth: "960px"
      }}
    >
      <ChatApp config={config} />
    </main>
  );
}
