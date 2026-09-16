// Issues a short-lived signed URL for a resident to view/download their own
// document file. The 'documents' storage bucket is private (no public
// access, no client-side storage RLS set up) — the only way a resident
// gets at the file is through this function, which verifies ownership via
// their own RLS-scoped session first, then uses service role just to mint
// the signed URL. Mirrors the auth-via-RLS-relay pattern used by
// support-bot and document-sign.
//
// Request:  POST { document_recipient_id: number }
//           Authorization: Bearer <resident's Supabase Auth access token>
// Response: { url: string, expires_in: number }

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const EXPIRES_IN_SECONDS = 300; // 5 minutes — just enough to open/download it

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const { document_recipient_id } = await req.json();
    if (!document_recipient_id) {
      return json({ error: "document_recipient_id is required" }, 400);
    }

    // Ownership check via the resident's own RLS-scoped session — a row
    // only comes back if document_recipients.resident_id is really theirs.
    const asUserClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: recipient, error: recErr } = await asUserClient
      .from("document_recipients")
      .select("id, document_version_id")
      .eq("id", document_recipient_id)
      .maybeSingle();
    if (recErr || !recipient) {
      return json({ error: "Document not found or not accessible." }, 403);
    }

    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: version, error: versionErr } = await serviceClient
      .from("document_versions")
      .select("file_url")
      .eq("id", recipient.document_version_id)
      .maybeSingle();
    if (versionErr || !version?.file_url || version.file_url.startsWith("pending-upload://")) {
      return json({ error: "הקובץ עדיין לא זמין." }, 404);
    }

    const { data: signed, error: signErr } = await serviceClient.storage
      .from("documents")
      .createSignedUrl(version.file_url, EXPIRES_IN_SECONDS);
    if (signErr || !signed) {
      throw signErr ?? new Error("Failed to create signed URL");
    }

    return json({ url: signed.signedUrl, expires_in: EXPIRES_IN_SECONDS });
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});
