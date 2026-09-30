// Self-test fixture with a type error, on purpose: one change narrowed
// ChangeArea, another added "infra" to the list. Each typechecked alone.
export type ChangeArea = "docs" | "go" | "ui" | "image";

export const changeAreas: readonly ChangeArea[] = ["docs", "go", "ui", "image", "infra"];
