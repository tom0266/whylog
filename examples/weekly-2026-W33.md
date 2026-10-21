# Weekly summary 2026-W33 (2026-08-10 ~ 2026-08-16)

_Generated from 5 daily logs. Originals are the dated files in this folder._

**Key results**
- Found and fixed a train/val leak; all baselines re-run on the corrected split.
- Data loading is about 3× faster (14 → 5 min per epoch).
- Results section of the paper draft updated with the corrected numbers.

**Progress by project**

### Data pipeline
At the start of the week, the loader was slow and nobody suspected the split. Profiling on Wednesday surfaced unusually high validation scores, which led to the leak: augmented copies were crossing the split. Deduplication now runs before splitting, and a guard check fails on any overlap. The pipeline is stable and covered by that check.

### Experiments
After the fix, the three baselines were re-run Thursday and Friday. The ranking between models did not change, but every absolute score dropped by 5–8 points. The ablation study is half done.

### Paper
Table 2 and the related text were rewritten with the new numbers. The methods section still describes the old split.

**Carried over**
- Finish the remaining ablations (2 of 4 left).
- Update the methods section to describe the new split.
- Decide whether to report the old numbers in the appendix.
