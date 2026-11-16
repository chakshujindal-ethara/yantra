# Generator size limits — what admins need to know

**The error:** *"The input token count exceeds the maximum number of tokens
allowed 1048576."*

> **If you hit this before 2026-09-15:** a bug sent sample-question files to the
> AI twice in the same request, which could double the largest item in your pile
> on its own. That is fixed. Press **Generate questions** once more before
> changing anything - a generator that failed only for that reason now succeeds
> untouched.

**What it means:** every file attached to a generator is sent to the AI in one
request. That request has a hard ceiling. Too much attached material and the run
is rejected before it starts. With that bug out of the way, the remaining cause
is the honest one: the pile is too big.

---

## The rule

**Keep everything attached to one generator under ~3 MB in total.**

Add up the Size column on the Resources tab. That's it. The ceiling is a little
higher, but 3 MB leaves room for the instructions and the questions themselves.

## Rough costs, if you want to reason about it

| What | Roughly costs |
|---|---|
| 1 MB of text, Markdown or Word | a quarter of the budget |
| A normal text PDF | ~250 per page — a 400-page PDF is about a tenth |
| A scanned or image-heavy PDF | **much** more per page. Treat these as expensive |

Numbers are approximate. The point is that **text files are heavier than they
look**, and a 2 MB Markdown file can cost more than a 200-page PDF.

## If you hit the error

1. Open the generator's **Resources** tab and add up the Size column.
2. Find the biggest file. It is usually one file causing it, not many.
3. **Sample questions first** (golden examples are sample questions now - one
   list). They should be a handful of worked examples, not a whole library. If a
   file is over ~200 KB, it is doing the wrong job - cut it to the 5–10 best
   examples.
4. Remove or replace the biggest SOP file. If you need all of it, split the work
   across two generators (see below).
5. Press **Generate questions** again.

**"Try Again" is worth exactly one press**, in case you hit the duplicate-send
bug above. If it fails a second time, the pile really is too big and something
has to come off.

## Splitting a generator

When the source material genuinely is large, make more than one generator
instead of one overloaded one:

- One per module, chapter, or topic, each with only the files for that part.
- Generate from each, then use them together in one assessment.

This also produces better questions. The AI writes sharper questions from 50
focused pages than from 500 pages where the topic is buried.

## Habits that avoid this entirely

- **Attach only what the questions come from.** Background reading that a human
  would skim is cost with no benefit.
- **Keep sample questions small.** They teach the AI the shape of a good question.
  Ten good ones beat a thousand.
- **Prefer a trimmed PDF over the full manual.** Cut the appendices, the revision
  history, the index.
- **Watch the Size column as you upload**, not after a failed run.

---

### Worked example — the "IG Entity" generator

| File | Size |
|---|---|
| vs-1784307533-ig-entity-tagging-videos-cleaning.pdf | 3.3 MB |
| ig-entity.md (sample questions) | 1.9 MB |
| Common Error (1).pdf | 102 KB |
| Clarification Questions - …pdf | 50 KB |
| **Total** | **~5.3 MB** |

Roughly double the working budget. The fastest fix: cut `ig-entity.md` down to
its best examples - a sample-question file at 1.9 MB is a library, not examples -
and if it still fails, split the 3.3 MB PDF across two generators.
