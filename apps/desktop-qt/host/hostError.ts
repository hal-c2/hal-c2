/** A start-up failure the shell shows the user as is. */
export class HostError extends Error {
  override readonly name = "HostError";
}
