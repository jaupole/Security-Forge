# Security Documentation

Security-specific documentation that's audit-relevant. Populated incrementally and reviewed at least quarterly.

## Expected files

| File | Purpose | First populated |
|---|---|---|
| `threat-model.md` | STRIDE-based threat model of the platform | After Phase 6 (initial — see line 31), updated each major phase |
| `hardening-checklist.md` | Reference to the HTML planning workspace + any platform-specific items not in it | Phase 10 |
| `compliance-readiness.md` | Cross-reference to SOC 2 + ISO 27001 readiness assessments in 06-reference | Phase 10 |
| `data-classification.md` | What data we have, where it lives, who can access it | Phase 9 |
| `vulnerability-management.md` | How we track and remediate CVEs | Phase 10 |

## Threat model template

A useful threat model has, at minimum:

1. **System diagram** with trust boundaries marked
2. **Data flows** with what crosses each boundary
3. **STRIDE per component**:
   - **S**poofing — can someone pretend to be someone else?
   - **T**ampering — can someone modify data they shouldn't?
   - **R**epudiation — can someone deny doing something?
   - **I**nformation disclosure — can someone see data they shouldn't?
   - **D**enial of service — can someone make the system unavailable?
   - **E**levation of privilege — can someone get more permissions than they should?
4. **Mitigations** for each identified threat
5. **Residual risks** — what remains, why we accept it

Have Claude Code build the initial threat model after Phase 6 (when most of the platform is in place) and update it each major phase.
