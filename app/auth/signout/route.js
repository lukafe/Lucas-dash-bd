import { NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase-server";

export async function POST(request) {
  await supabaseServer().auth.signOut();
  return NextResponse.redirect(new URL("/login", request.url), { status: 303 });
}
