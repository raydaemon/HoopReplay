import type { Game, Team } from "./types";
import { supabase, syncSpace } from "./supabase";

export type AccessSubject = "user" | "club" | "team" | "everyone";
export type AccessRole = "editor" | "viewer";
export type GamePermission = {
  id: string; role: AccessRole; subject_type: AccessSubject;
  subject_email: string | null; subject_club_id: string | null; subject_team_id: number | null;
};
export type Club = { id: string; name: string };
export type ClubMember = { club_id: string; member_email: string };
export type TeamMember = { team_id: number; member_email: string };

function client() {
  if (!supabase) throw new Error("Supabase is not configured.");
  return supabase;
}

export async function loadAccessManagement(game: Game, userId: string) {
  const ownerId = game.owner_id ?? userId;
  const space = game.cloud_sync_space ?? syncSpace;
  const [permissions, clubs, clubMembers, teamMembers] = await Promise.all([
    client().from("hoop_game_permissions").select("id,role,subject_type,subject_email,subject_club_id,subject_team_id")
      .eq("owner_id", ownerId).eq("sync_space", space).eq("game_id", game.id).order("created_at"),
    client().from("hoop_clubs").select("id,name").eq("owner_id", ownerId).order("name"),
    client().from("hoop_club_members").select("club_id,member_email").order("member_email"),
    client().from("hoop_team_members").select("team_id,member_email").eq("owner_id", ownerId).eq("sync_space", space).order("member_email"),
  ]);
  const failure = [permissions, clubs, clubMembers, teamMembers].find(result => result.error)?.error;
  if (failure) throw failure;
  return {
    permissions: (permissions.data ?? []) as GamePermission[],
    clubs: (clubs.data ?? []) as Club[],
    clubMembers: (clubMembers.data ?? []) as ClubMember[],
    teamMembers: (teamMembers.data ?? []) as TeamMember[],
  };
}

export async function addGamePermission(game: Game, userId: string, role: AccessRole, subject: AccessSubject, value?: string) {
  const row = {
    owner_id: game.owner_id ?? userId,
    sync_space: game.cloud_sync_space ?? syncSpace,
    game_id: game.id,
    role,
    subject_type: subject,
    subject_email: subject === "user" ? value?.trim().toLowerCase() : null,
    subject_club_id: subject === "club" ? value : null,
    subject_team_id: subject === "team" ? Number(value) : null,
  };
  const { error } = await client().from("hoop_game_permissions").insert(row);
  if (error) throw error;
}

export async function removeGamePermission(id: string) {
  const { error } = await client().from("hoop_game_permissions").delete().eq("id", id);
  if (error) throw error;
}

export async function createClub(name: string, ownerId: string) {
  const { error } = await client().from("hoop_clubs").insert({ owner_id: ownerId, name: name.trim() });
  if (error) throw error;
}

export async function loadClubs(ownerId: string) {
  const { data, error } = await client().from("hoop_clubs").select("id,name").eq("owner_id", ownerId).order("name");
  if (error) throw error;
  return (data ?? []) as Club[];
}

export async function loadClubMembers(clubId: string) {
  const { data, error } = await client().from("hoop_club_members").select("club_id,member_email").eq("club_id", clubId).order("member_email");
  if (error) throw error;
  return (data ?? []) as ClubMember[];
}

export async function loadTeamMembers(team: Team, userId: string) {
  const { data, error } = await client().from("hoop_team_members").select("team_id,member_email")
    .eq("owner_id", team.owner_id ?? userId).eq("sync_space", team.cloud_sync_space ?? syncSpace)
    .eq("team_id", team.id).order("member_email");
  if (error) throw error;
  return (data ?? []) as TeamMember[];
}

export async function addClubMember(clubId: string, email: string) {
  const { error } = await client().from("hoop_club_members").upsert({ club_id: clubId, member_email: email.trim().toLowerCase() });
  if (error) throw error;
}

export async function removeClubMember(clubId: string, email: string) {
  const { error } = await client().from("hoop_club_members").delete().eq("club_id", clubId).eq("member_email", email);
  if (error) throw error;
}

export async function addTeamMember(team: Team, userId: string, email: string) {
  const { error } = await client().from("hoop_team_members").upsert({
    owner_id: team.owner_id ?? userId,
    sync_space: team.cloud_sync_space ?? syncSpace,
    team_id: team.id,
    member_email: email.trim().toLowerCase(),
  });
  if (error) throw error;
}

export async function removeTeamMember(team: Team, userId: string, email: string) {
  const { error } = await client().from("hoop_team_members").delete()
    .eq("owner_id", team.owner_id ?? userId).eq("sync_space", team.cloud_sync_space ?? syncSpace)
    .eq("team_id", team.id).eq("member_email", email);
  if (error) throw error;
}
