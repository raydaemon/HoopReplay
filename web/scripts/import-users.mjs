#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { createClient } from "@supabase/supabase-js";

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;

  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (character === '"') {
      if (quoted && text[index + 1] === '"') {
        field += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (character === "," && !quoted) {
      row.push(field);
      field = "";
    } else if ((character === "\n" || character === "\r") && !quoted) {
      if (character === "\r" && text[index + 1] === "\n") index += 1;
      row.push(field);
      if (row.some((value) => value.length > 0)) rows.push(row);
      row = [];
      field = "";
    } else {
      field += character;
    }
  }

  if (quoted) throw new Error("CSV contains an unterminated quoted field");
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

function loadCredentials(text) {
  const rows = parseCsv(text);
  const header = rows.shift()?.map((value) => value.trim().toLowerCase());
  if (!header) throw new Error("users.csv is empty");

  const emailIndex = header.indexOf("email");
  const passwordIndex = header.indexOf("password");
  if (emailIndex < 0 || passwordIndex < 0) {
    throw new Error("users.csv must contain email and password columns");
  }

  const credentials = rows.map((values, rowIndex) => ({
    email: (values[emailIndex] ?? "").trim().toLowerCase(),
    password: values[passwordIndex] ?? "",
    rowNumber: rowIndex + 2,
  }));

  for (const credential of credentials) {
    if (!credential.email || !credential.email.includes("@")) {
      throw new Error(`Invalid email on CSV row ${credential.rowNumber}`);
    }
    if (!credential.password) {
      throw new Error(`Missing password on CSV row ${credential.rowNumber}`);
    }
  }

  const duplicate = credentials.find(
    (credential, index) => credentials.findIndex(({ email }) => email === credential.email) !== index,
  );
  if (duplicate) throw new Error(`Duplicate email in users.csv: ${duplicate.email}`);
  return credentials;
}

async function listUsersByEmail(admin) {
  const usersByEmail = new Map();
  const perPage = 1000;

  for (let page = 1; ; page += 1) {
    const { data, error } = await admin.listUsers({ page, perPage });
    if (error) throw error;
    for (const user of data.users) {
      if (user.email) usersByEmail.set(user.email.toLowerCase(), user);
    }
    if (data.users.length < perPage) return usersByEmail;
  }
}

const csvPath = resolve(process.argv[2] ?? "data/users.csv");
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const secretKey = process.env.SUPABASE_SECRET_KEY;
if (!supabaseUrl || !secretKey) {
  throw new Error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SECRET_KEY are required");
}

const credentials = loadCredentials(await readFile(csvPath, "utf8"));
const supabase = createClient(supabaseUrl, secretKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const usersByEmail = await listUsersByEmail(supabase.auth.admin);
let created = 0;
let updated = 0;

for (const { email, password } of credentials) {
  const existing = usersByEmail.get(email);
  if (existing) {
    const { error } = await supabase.auth.admin.updateUserById(existing.id, { password });
    if (error) throw new Error(`Unable to update ${email}: ${error.message}`);
    updated += 1;
    console.log(`  updated ${email}`);
  } else {
    const { error } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (error) throw new Error(`Unable to create ${email}: ${error.message}`);
    created += 1;
    console.log(`  created ${email}`);
  }
}

console.log(`Imported ${credentials.length} users (${created} created, ${updated} updated).`);
