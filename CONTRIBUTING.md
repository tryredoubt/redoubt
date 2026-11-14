# Contributing

## Submitting changes

Send changes as pull requests against this repository. Keep commits
small, name them by what they change, and state why. A change that adds
a dependency must also update THIRD-PARTY-NOTICES.md with the new
component, its version, source, copyright and license, and state
whether the kit downloads or redistributes it.

## License of contributions

Contributions are made under AGPL-3.0-only, the same terms as the kit
(see the License section of README.md and the LICENSE file). There is
no contributor license agreement, and submitting a change grants no
automatic right to relicense it under proprietary terms. Keep
third-party code out of your changes unless its license is compatible
and recorded in THIRD-PARTY-NOTICES.md.

## Testing

Test before you submit:

- Run `bash -n` on the changed script. Fix every syntax error.
- Run shellcheck on the changed sections when available and fix the
  findings that matter.
- Do a fresh install in the test jail: a clean jail or VM, first run
  through the dashboard, then a second run to exercise the resume path.
- Keep secrets out of tests. Never commit keys, passwords, or a test
  machine's real identity data.

## Reporting security issues

Do not report security issues in public issues. See SECURITY.md and
write to hello@tryredoubt.com.
