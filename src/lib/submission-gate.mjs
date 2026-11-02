export function createSubmissionGate() {
  let isSubmitting = false;

  /**
   * @template Result
   * @param {() => Promise<Result>} submit
   * @returns {Promise<Result | { status: "already_submitting" }>}
   */
  return async function run(submit) {
    if (isSubmitting) return { status: "already_submitting" };
    isSubmitting = true;
    try {
      return await submit();
    } finally {
      isSubmitting = false;
    }
  };
}
