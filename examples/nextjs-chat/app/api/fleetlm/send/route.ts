import { NextRequest, NextResponse } from "next/server";
import { sendUserMessage } from "@/lib/fleetlm";

const DEFAULT_USER =
  process.env.FLEETLM_DEMO_USER_ID ??
  process.env.NEXT_PUBLIC_FLEETLM_USER_ID ??
  "nextjs-demo-user";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();

    const sessionId = typeof body.sessionId === "string" ? body.sessionId : null;
    const text = typeof body.text === "string" ? body.text : "";
    const userId = typeof body.userId === "string" ? body.userId : DEFAULT_USER;

    if (!sessionId) {
      return NextResponse.json({ error: "sessionId is required" }, { status: 422 });
    }

    if (!text.trim()) {
      return NextResponse.json({ error: "text is required" }, { status: 422 });
    }

    const message = await sendUserMessage(sessionId, userId, text.trim());
    return NextResponse.json({ message });
  } catch (error) {
    console.error(error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}
