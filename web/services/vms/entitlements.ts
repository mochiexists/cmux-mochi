import type { AuthedUser } from "./auth";
import type { BillingCustomerType } from "./billingGateway";

export type VmEntitlements = {
  readonly planId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly maxActiveVms: number;
};

export type VmEntitlementOptions = {
  readonly requestedBillingTeamId?: string | null;
  readonly requireTeam?: boolean;
};

export type VmBillingTeamErrorCode =
  | "vm_billing_team_required"
  | "vm_billing_team_not_found";

export class VmBillingTeamResolutionError extends Error {
  readonly code: VmBillingTeamErrorCode;
  readonly status: number;

  constructor(input: {
    readonly code: VmBillingTeamErrorCode;
    readonly status: number;
    readonly message: string;
  }) {
    super(input.message);
    this.name = "VmBillingTeamResolutionError";
    this.code = input.code;
    this.status = input.status;
  }
}

export function resolveVmEntitlements(
  user: AuthedUser,
  env: Record<string, string | undefined> = process.env,
  _options: VmEntitlementOptions = {},
): VmEntitlements {
  void _options;
  const billing = resolveBillingContext(user);
  const planId = normalizedPlanId(billing.billingPlanId ?? env.CMUX_VM_DEFAULT_PLAN ?? "free");
  return {
    planId,
    billingCustomerType: billing.billingCustomerType,
    billingTeamId: billing.billingTeamId,
    maxActiveVms: activeVmLimitForPlan(planId, env),
  };
}

export function isVmBillingTeamResolutionError(err: unknown): err is VmBillingTeamResolutionError {
  return err instanceof VmBillingTeamResolutionError;
}

function resolveBillingContext(
  user: AuthedUser,
): {
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string | null;
} {
  return {
    billingCustomerType: "user",
    billingTeamId: user.id,
    billingPlanId: user.userBillingPlanId,
  };
}

function activeVmLimitForPlan(planId: string, env: Record<string, string | undefined>): number {
  const planKey = planId.replace(/[^a-zA-Z0-9]/g, "_").toUpperCase();
  const specific = env[`CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`];
  if (specific?.trim()) return positiveInteger(specific, `CMUX_VM_PLAN_${planKey}_MAX_ACTIVE_VMS`);

  if (planId === "free") {
    return positiveInteger(env.CMUX_VM_FREE_MAX_ACTIVE_VMS ?? "1", "CMUX_VM_FREE_MAX_ACTIVE_VMS");
  }

  return positiveInteger(env.CMUX_VM_PAID_MAX_ACTIVE_VMS ?? "10", "CMUX_VM_PAID_MAX_ACTIVE_VMS");
}

function normalizedPlanId(planId: string): string {
  const normalized = planId.trim().toLowerCase();
  return normalized || "free";
}

function positiveInteger(raw: string, key: string): number {
  const value = raw.trim();
  if (!/^\d+$/.test(value)) throw new Error(`${key} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${key} must be a positive integer`);
  return parsed;
}
