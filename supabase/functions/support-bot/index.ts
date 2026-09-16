// עידן — Upper's support bot Edge Function.
//
// Called by the resident app (Lovable) after it has already inserted the
// resident's new message into `support_messages` (both writes go through
// the resident's own authenticated Supabase client, so they're subject to
// the normal RLS policies from 20260915120000_support_bot_schema.sql —
// this function never creates the first message or the conversation row).
//
// Request:  POST { conversation_id: string }
//           Authorization: Bearer <resident's Supabase Auth access token>
// Response: { reply: string, status: string }
//
// See docs: support-bot-system-prompt.md and תכנון-בסיס-נתונים-קהילות.md
// (sections 30-33) for the full design this implements.

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

// --- System prompt (verbatim from support-bot-system-prompt.md, stages 1-3) ---
// The dynamic category list (33.2) is appended at the bottom at request time,
// never hardcoded here — so a new category added in Retool is picked up
// immediately without touching this file.
const SYSTEM_PROMPT_BASE = `# בוט תמיכה — Upper

## מי אנחנו
Upper היא פלטפורמת ניהול קהילה למתחמי מגורים בישראל. את/ה שכבת
התמיכה הראשונה בתוך אפליקציית הדיירים ותוכנת הניהול. יש לך גישה
לבסיס ידע, ליכולת לבדוק סטטוס אישי של הפונה עצמו/ה בלבד, וליכולת
להעביר פנייה לצוות אנושי.

## טרמינולוגיה
- **קהילה** — מתחם מגורים בודד. **מגדל/בניין** — מבנה בתוך קהילה.
- **דייר** — משתמש באפליקציה. **בעלים/שוכר** — סוגי מחזיק ביחידה.
- **ליב** — הסוכנת שמנהלת את הקהילה עצמה (אירועים, ספקים, מסמכים) — לא את/ה.
- **מועדון צרכנות** — מאגר בעלי מקצוע ומבצעים. **משאבים** — אולם/חדר כושר/רכבים שיתופיים.
- **קריאת שירות** — הפנייה שנוצרת כשמעבירים לצוות אנושי (escalate_to_staff).

## איך את/ה מתנהג/ת
- טון חם, קצר וישיר — לא רשמי מדי, לא "צ'אטי" מדי.
- עונה/ה באותה שפה שבה נכתבה השאלה.
- שואל/ת שאלת הבהרה אחת אם השאלה מעורפלת, לפני שממציא/ה תשובה או מפעיל/ה כלי.
- לעולם לא ממציא/ה מידע — אם אין תשובה בבסיס הידע ואין כלי מתאים, אומר/ת זאת בכנות.

## מקורות מידע וכלים

1. search_knowledge_base(query) — לשאלות "איך עושים X". תמיד המקור הראשון לבדוק, גם לפני שחושבים על הסלמה.
2. get_document_status() — לשאלות כמו "האם המסמך שלי אושר?". תמיד עבור הפונה/ה עצמו/ה בלבד — גם אם המשתמש/ת מבקש/ת מפורשות לבדוק עבור שכן/ה או בן משפחה, מסרבים בנימוס ומסבירים שזה מוגן פרטיות. (הכלי הזה תמיד בודק את הפונה הנוכחי בלבד — אין אפשרות טכנית לבדוק דייר אחר, גם אם תנסה/י.)
3. get_resource_availability(resource_id) — לשאלות כמו "האם הרכב פנוי מחר?". אין הגבלת פרטיות כאן (זמינות משאב היא מידע ציבורי בתוך הקהילה) — התוצאה כוללת רק זמנים וסטטוס, לא מי הזמין.
4. escalate_to_staff(category_id, priority, summary) — כשלא ניתן לפתור עם שני הכלים הקודמים, או כשהמשתמש/ת מבקש/ת מפורשות "לדבר עם נציג/ה".
   - category_id — נבחר מתוך רשימת הקטגוריות התקפות שסופקה בהמשך (טבלה חיה, לא רשימה סגורה).
   - priority:
     | דחיפות | קריטריון |
     |---|---|
     | urgent | סכנה/בטיחות, תקלה שחוסמת גישה לדירה/בניין, תשלום שנכשל וחוסם שימוש |
     | high | תקלה שמשפיעה על כמה דיירים, בקשה רגישה בזמן |
     | normal | שאלה/בקשה שגרתית שלא חוסמת כלום |
     | low | משוב, הצעה, לא דחוף |
   - summary — 2-3 משפטים בעברית ברורה, מנקודת מבט הצוות שיקבל את הפנייה (לא "המשתמש שאל..." אלא תיאור הבעיה עצמה).
   - אחרי הסלמה: מודיע/ה למשתמש/ת בפשטות שהפנייה הועברה, בלי להבטיח זמן תגובה קונקרטי.

## Guardrails
- לעולם לא ממציא/ה תשובה שלא מבוססת על בסיס הידע או על תוצאת כלי.
- לעולם לא בוחר/ת category_id או priority מחוץ לרשימות שסופקו — אם לא בטוח/ה, category_id כללי ו-priority של normal.
- לעולם לא נותן/ת ייעוץ משפטי, פיננסי או רפואי.
- לעולם לא מבצע/ת פעולת כתיבה על נתונים (עדיין אין כלים כאלה בשלב זה).
- אם מזהה/ה תוכן שמרמז על מצוקה אמיתית (בטיחות, בריאות נפשית, אלימות) — עוצר/ת מיד, מפעיל/ה escalate_to_staff עם priority="urgent", ולא מנסה "לטפל" בעצמו/ה.
- בנושאים רגישים (תשלומים, תלונות, סכסוכים) — טון רציני, בלי הומור.
- כשלא בטוח/ה: מעדיף/ה להסלים על פני ניחוש.`;

interface ToolResult {
  tool_use_id: string;
  content: string;
  is_error?: boolean;
}

async function runSupportBot(
  serviceClient: SupabaseClient,
  conversationId: string,
  communityId: string | null,
  requesterType: string,
  requesterId: string,
): Promise<{ reply: string; status: string }> {
  // Load full message history for this conversation.
  const { data: messages, error: msgErr } = await serviceClient
    .from("support_messages")
    .select("sender_type, body, created_at")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: true });
  if (msgErr) throw msgErr;

  // Dynamic category list (33.2) — never hardcoded.
  const { data: categories } = await serviceClient
    .from("support_categories")
    .select("id, key, label, default_priority");

  const categoryList = (categories ?? [])
    .map((c) => `- id=${c.id}, key="${c.key}", label="${c.label}"`)
    .join("\n") || "(אין קטגוריות מוגדרות עדיין — השתמש/י ב-category_id הראשון הזמין, אם יש)";

  const systemPrompt = `${SYSTEM_PROMPT_BASE}\n\n## רשימת הקטגוריות התקפות כרגע (33.2)\n${categoryList}`;

  const anthropicMessages = messages!.map((m) => ({
    role: m.sender_type === "user" ? "user" : "assistant",
    content: m.body,
  }));

  const tools = [
    {
      name: "search_knowledge_base",
      description: "מחפש בבסיס הידע של הקהילה תשובה לשאלת 'איך עושים X'.",
      input_schema: {
        type: "object",
        properties: { query: { type: "string", description: "מילות החיפוש" } },
        required: ["query"],
      },
    },
    {
      name: "get_document_status",
      description: "בודק את סטטוס המסמכים (ממתין/נצפה/נחתם/נדחה) של הפונה/ה הנוכחי/ת בלבד. אין פרמטרים — הכלי תמיד בודק את הפונה הנוכחי.",
      input_schema: { type: "object", properties: {} },
    },
    {
      name: "get_resource_availability",
      description: "בודק זמינות של משאב משותף (אולם, חדר כושר, רכב וכו') לימים הקרובים.",
      input_schema: {
        type: "object",
        properties: { resource_id: { type: "string", description: "UUID של המשאב" } },
        required: ["resource_id"],
      },
    },
    {
      name: "escalate_to_staff",
      description: "מעביר את הפנייה לטיפול צוות אנושי, עם קטגוריה, דחיפות ותקציר.",
      input_schema: {
        type: "object",
        properties: {
          category_id: { type: "integer", description: "id מתוך רשימת הקטגוריות התקפות" },
          priority: { type: "string", enum: ["low", "normal", "high", "urgent"] },
          summary: { type: "string", description: "2-3 משפטים בעברית מנקודת מבט הצוות" },
        },
        required: ["category_id", "priority", "summary"],
      },
    },
  ];

  let finalText = "";
  let conversationStatus = "open";

  // Tool-calling loop, capped to avoid runaway cost on a stuck conversation.
  for (let turn = 0; turn < 5; turn++) {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY!,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-sonnet-5",
        max_tokens: 1024,
        system: systemPrompt,
        tools,
        messages: anthropicMessages,
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`Anthropic API error ${resp.status}: ${errText}`);
    }
    const data = await resp.json();

    const textBlocks = (data.content ?? []).filter((b: any) => b.type === "text");
    const toolUseBlocks = (data.content ?? []).filter((b: any) => b.type === "tool_use");

    finalText = textBlocks.map((b: any) => b.text).join("\n").trim();

    if (data.stop_reason !== "tool_use" || toolUseBlocks.length === 0) {
      break; // Claude gave a final answer — done.
    }

    // Append the assistant's tool-call turn, then execute each tool.
    anthropicMessages.push({ role: "assistant", content: data.content });

    const toolResults: ToolResult[] = [];
    for (const block of toolUseBlocks) {
      try {
        const result = await executeTool(
          serviceClient,
          block.name,
          block.input,
          { conversationId, communityId, requesterType, requesterId },
        );
        if (block.name === "escalate_to_staff") conversationStatus = "escalated";
        toolResults.push({ tool_use_id: block.id, content: JSON.stringify(result) });
      } catch (e) {
        toolResults.push({
          tool_use_id: block.id,
          content: `שגיאה בהרצת הכלי: ${(e as Error).message}`,
          is_error: true,
        });
      }
    }

    anthropicMessages.push({
      role: "user",
      content: toolResults.map((r) => ({
        type: "tool_result",
        tool_use_id: r.tool_use_id,
        content: r.content,
        is_error: r.is_error ?? false,
      })),
    });
  }

  if (!finalText) {
    finalText = "מצטער/ת, לא הצלחתי לגבש תשובה כרגע. נסי/נסה לנסח את השאלה מחדש, או שאעביר את זה לצוות.";
  }

  // Record the bot's reply in the same thread the resident and staff see.
  const { error: insertErr } = await serviceClient.from("support_messages").insert({
    conversation_id: conversationId,
    sender_type: "bot",
    body: finalText,
  });
  if (insertErr) throw insertErr;

  if (conversationStatus === "escalated") {
    // status itself was already set inside the escalate_to_staff tool;
    // this just reports it back to the caller.
  } else {
    // Bot answered without escalating — mark it as bot-resolved unless the
    // conversation was already further along (defensive: don't downgrade
    // a conversation a staff member is already handling).
    const { data: conv } = await serviceClient
      .from("support_conversations")
      .select("status")
      .eq("id", conversationId)
      .single();
    if (conv && conv.status === "open") {
      await serviceClient
        .from("support_conversations")
        .update({ status: "resolved_by_bot" })
        .eq("id", conversationId);
      conversationStatus = "resolved_by_bot";
    } else if (conv) {
      conversationStatus = conv.status;
    }
  }

  return { reply: finalText, status: conversationStatus };
}

async function executeTool(
  serviceClient: SupabaseClient,
  name: string,
  input: any,
  ctx: { conversationId: string; communityId: string | null; requesterType: string; requesterId: string },
) {
  switch (name) {
    case "search_knowledge_base": {
      const query: string = String(input?.query ?? "").trim();
      if (!query) return { results: [] };
      // TODO(v2): this is plain ILIKE text search, not the pgvector semantic
      // search from section 31.3 — support_knowledge_base.embedding is not
      // populated yet (no ingestion pipeline built). Upgrade path: generate
      // an embedding whenever an article is created/edited in the Retool
      // "בסיס ידע" screen, store it in `embedding`, then switch this query
      // to `ORDER BY embedding <=> query_embedding`. See memory note
      // "project-support-bot-semantic-search".
      const { data, error } = await serviceClient
        .from("support_knowledge_base")
        .select("title, content")
        .is("archived_at", null)
        .or(`community_id.is.null${ctx.communityId ? `,community_id.eq.${ctx.communityId}` : ""}`)
        .or(`title.ilike.%${query}%,content.ilike.%${query}%`)
        .limit(3);
      if (error) throw error;
      return { results: data ?? [] };
    }

    case "get_document_status": {
      // Hard guardrail: always the conversation's own requester, never a
      // client-supplied id, no matter what the model passes.
      if (ctx.requesterType !== "resident") {
        return { error: "זמין רק לפניות של דיירים." };
      }
      const { data, error } = await serviceClient
        .from("document_recipients")
        .select("status, document_versions(document_id, documents(title))")
        .eq("resident_id", ctx.requesterId);
      if (error) throw error;
      const items = (data ?? []).map((r: any) => ({
        title: r.document_versions?.documents?.title ?? "מסמך",
        status: r.status,
      }));
      return { documents: items };
    }

    case "get_resource_availability": {
      const resourceId = String(input?.resource_id ?? "");
      const { data: resource, error: resErr } = await serviceClient
        .from("community_resources")
        .select("id, name, category, capacity, booking_mode")
        .eq("id", resourceId)
        .eq("community_id", ctx.communityId)
        .maybeSingle();
      if (resErr) throw resErr;
      if (!resource) return { error: "משאב לא נמצא בקהילה שלך." };

      const from = new Date();
      const to = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
      const { data: busy, error: busyErr } = await serviceClient.rpc("resource_busy_slots", {
        _resource_id: resourceId,
        _from: from.toISOString(),
        _to: to.toISOString(),
      });
      if (busyErr) throw busyErr;
      return { resource, busy_slots: busy ?? [] };
    }

    case "escalate_to_staff": {
      const categoryId = Number(input?.category_id);
      const priority = String(input?.priority ?? "normal");
      const summary = String(input?.summary ?? "").trim();

      const { data: cat } = await serviceClient
        .from("support_categories")
        .select("id")
        .eq("id", categoryId)
        .maybeSingle();
      if (!cat) return { error: "category_id לא תקין — בחר/י מהרשימה שסופקה." };
      if (!["low", "normal", "high", "urgent"].includes(priority)) {
        return { error: "priority לא תקין." };
      }

      const { error } = await serviceClient
        .from("support_conversations")
        .update({ category_id: categoryId, priority, summary, status: "escalated" })
        .eq("id", ctx.conversationId);
      if (error) throw error;
      return { escalated: true };
    }

    default:
      return { error: `כלי לא מוכר: ${name}` };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const { conversation_id } = await req.json();
    if (!conversation_id) return json({ error: "conversation_id is required" }, 400);

    // 1) Verify the caller actually owns this conversation, by querying it
    // through their own RLS-scoped session — never trust the id blindly.
    const asUserClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: conv, error: convErr } = await asUserClient
      .from("support_conversations")
      .select("id, community_id, requester_type, requester_id")
      .eq("id", conversation_id)
      .maybeSingle();
    if (convErr || !conv) {
      return json({ error: "Conversation not found or not accessible." }, 403);
    }

    // 2) Switch to the service-role client for the tool implementations,
    // which need broader read access than a resident's own RLS allows
    // (e.g. reading resource_bookings across all residents to check
    // availability) — every query below is still manually scoped in code
    // to conv.community_id / conv.requester_id, never to caller input.
    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const result = await runSupportBot(
      serviceClient,
      conv.id,
      conv.community_id,
      conv.requester_type,
      conv.requester_id,
    );

    return json(result);
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});
