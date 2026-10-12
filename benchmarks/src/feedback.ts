import { HttpError } from "./http";
// Ratings are canonical native feedback events in an explicitly opened cloud revision.
// A separate mutable overlay would invalidate frozen validation and contribution consent.
export async function reviseFeedback(
  _request: Request,
  _env: Env,
  _owner: string,
  _sid: string,
  _ctx: ExecutionContext,
): Promise<Response> {
  throw new HttpError(409, "append_feedback_in_new_revision");
}
