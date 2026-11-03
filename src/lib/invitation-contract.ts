export type InvitationPreview =
  | { status: "unavailable" }
  | {
      status: "available";
      board_name: string;
      inviter: string;
      role: "collaborator";
    };

const previewKeys = ["board_name", "inviter", "role", "status"] as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Restrict invitation previews to the metadata approved by C-98. */
export function parseInvitationPreview(value: unknown): InvitationPreview {
  if (!isRecord(value) || value.status !== "available") {
    return { status: "unavailable" };
  }

  const keys = Object.keys(value).sort();
  if (
    keys.length !== previewKeys.length ||
    keys.some((key, index) => key !== previewKeys[index]) ||
    typeof value.board_name !== "string" ||
    value.board_name.length === 0 ||
    typeof value.inviter !== "string" ||
    value.inviter.length === 0 ||
    value.role !== "collaborator"
  ) {
    return { status: "unavailable" };
  }

  return {
    status: "available",
    board_name: value.board_name,
    inviter: value.inviter,
    role: "collaborator",
  };
}
