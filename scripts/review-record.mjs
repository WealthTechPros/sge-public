/**
 * review-record.mjs — read a review record in preference to PR-body comment
 * markers (sge#3322, ADLC epic sge#3320). Used by /sge:governance-trace and
 * /sge:regulatory-trace: when a record exists its tier and verdict win over the
 * `sge-governance-tier` and `sge-phase5-verdict` markers, which stay a fallback
 * for PRs that predate the record. Node built-ins only.
 */

/**
 * @param {{record: object|null, markers: {tier?: string, verdict?: string}|null}} input
 * @returns {{tier: string|null, verdict: string|null, source: "review-record"|"markers"|"none"}}
 */
export function resolveTierAndVerdict({ record, markers }) {
  if (record?.tier?.resolved && record?.review?.verdict) {
    return { tier: record.tier.resolved, verdict: record.review.verdict, source: "review-record" };
  }
  if (markers && (markers.tier || markers.verdict)) {
    return { tier: markers.tier ?? null, verdict: markers.verdict ?? null, source: "markers" };
  }
  return { tier: null, verdict: null, source: "none" };
}
