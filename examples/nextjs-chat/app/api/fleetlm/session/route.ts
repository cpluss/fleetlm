import { NextRequest, NextResponse } from "next/server";
import { createSession, listSessions } from "@/lib/fleetlm";

const DEFAULT_USER =
  process.env.FLEETLM_DEMO_USER_ID ??
  process.env.NEXT_PUBLIC_FLEETLM_USER_ID ??
  "nextjs-demo-user";
const DEFAULT_AGENT =
  process.env.FLEETLM_AGENT_ID ?? process.env.NEXT_PUBLIC_FLEETLM_AGENT_ID ?? "nextjs-demo-agent";

function resolveBody(json: any) {
  if (json && typeof json === "object") {
    return json;
  }

  return {};
}

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const userId = searchParams.get("user_id") ?? DEFAULT_USER;

  try {
    const sessions = await listSessions(userId);
    return NextResponse.json({ sessions });
  } catch (error) {
    console.error(error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}

export async function POST(req: NextRequest) {
  let body: any = {};

  try {
    body = resolveBody(await req.json());
  } catch (_err) {
    body = {};
  }

  const userId = typeof body.userId === "string" ? body.userId : DEFAULT_USER;
  const agentId = typeof body.agentId === "string" ? body.agentId : DEFAULT_AGENT;

  try {
    const session = await createSession(userId, agentId);
    return NextResponse.json({ session });
  } catch (error) {
    console.error(error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}
