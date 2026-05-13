import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";

export type AuthedUser = {
  id: string;
  displayName: string | null;
  primaryEmail: string | null;
  billingCustomerType: "team" | "user";
  billingTeamId: string;
  selectedTeamId: string | null;
  teams: readonly AuthedTeam[];
  teamIds: readonly string[];
  userBillingPlanId: string | null;
  billingPlanId: string | null;
};

export type AuthedTeam = {
  id: string;
  billingPlanId: string | null;
};

/**
 * Verify the caller's Stack Auth session. Accepts either a cookie (browser path) or a
 * `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>` pair from the
 * native macOS client.
 *
 * Returns the resolved user or null if unauthenticated.
 */
export async function verifyRequest(request: Request): Promise<AuthedUser | null> {
  if (!isStackConfigured()) {
    return null;
  }

  const stackServerApp = getStackServerApp();
  const authHeader = request.headers.get("authorization");
  const refreshHeader = request.headers.get("x-stack-refresh-token");

  if (authHeader?.toLowerCase().startsWith("bearer ") && refreshHeader) {
    const accessToken = authHeader.slice("bearer ".length).trim();
    const refreshToken = refreshHeader.trim();
    if (accessToken && refreshToken) {
      const user = await stackServerApp.getUser({
        tokenStore: { accessToken, refreshToken },
      });
      if (user) {
        return await authedUserFromStackUser(user);
      }
    }
  }

  // Fall back to the Next.js cookie flow (when browser hits the route).
  const user = await stackServerApp.getUser({ tokenStore: request as unknown as { headers: { get(name: string): string | null } } });
  if (user) {
    return await authedUserFromStackUser(user);
  }
  return null;
}

async function authedUserFromStackUser(user: StackUserLike): Promise<AuthedUser> {
  const userBillingPlanId = planIdFromMetadata(user.clientReadOnlyMetadata) ?? null;

  return {
    id: user.id,
    displayName: user.displayName,
    primaryEmail: user.primaryEmail,
    billingCustomerType: "user",
    billingTeamId: user.id,
    selectedTeamId: null,
    teams: [],
    teamIds: [],
    userBillingPlanId,
    billingPlanId: userBillingPlanId,
  };
}

type StackUserLike = {
  readonly id: string;
  readonly displayName: string | null;
  readonly primaryEmail: string | null;
  readonly clientReadOnlyMetadata?: unknown;
};

function planIdFromMetadata(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== "object") return null;
  const value = (metadata as { cmuxVmPlan?: unknown; cmuxPlan?: unknown }).cmuxVmPlan ??
    (metadata as { cmuxPlan?: unknown }).cmuxPlan;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export function unauthorized(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "content-type": "application/json" },
  });
}
