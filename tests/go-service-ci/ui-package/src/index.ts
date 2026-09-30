// Self-test fixture: something for go-service-ci's ui job to typecheck and build.
export type ChangeArea = "docs" | "go" | "ui" | "image";

export const changeAreas: readonly ChangeArea[] = ["docs", "go", "ui", "image"];
