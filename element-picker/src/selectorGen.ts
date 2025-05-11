import { scoreForClassName } from "./gibberish";

// Our candidates have at most 3 terms
interface Candidate {
    terms: Term[]; // first is highest in the tree, bottom is original
    // hasTerms: Term[]; // for :has selectors; Do not implement yet

    topMatch: HTMLElement // the element corresponding to the highest parent we've traversed (or self)

    score: number; // higher is better. Bump the score for good terms; reduce it for bad terms
    matchCount: number;
}

interface Term {
    tag?: string;
    className?: string;
    id?: string;
    
    hasAttr?: string;
    attrVal?: string;

    lastChild?: boolean;
    nthChild?: number;

    directChild?: boolean; // do we prepend > before this term?
} 

function termToString(term: Term): string {
    let selectors: string[] = [];

    if (term.directChild) {
        selectors.push('>');
    }

    if (term.tag) {
        selectors.push(term.tag);
    } else if (!term.className && !term.id && !term.hasAttr) {
        selectors.push('*');
    }

    if (term.id) {
        selectors.push(`#${term.id}`);
    }

    if (term.className) {
        selectors.push(`.${term.className}`);
    }

    if (term.hasAttr) {
        if (term.attrVal) {
            selectors.push(`[${term.hasAttr}="${term.attrVal}"]`);
        } else {
            selectors.push(`[${term.hasAttr}]`);
        }
    }

    if (term.nthChild) {
        selectors.push(`:nth-child(${term.nthChild})`);
    } else if (term.lastChild) {
        selectors.push(':last-child');
    }

    return selectors.join('');
}

function candidateToString(cand: Candidate): string {
    return cand.terms.map(term => termToString(term)).join(' ');
}

function matchCount(terms: Term[]): number {
    let sel = terms.map(t => termToString(t)).join(' ');
    return document.querySelectorAll(sel).length;
}

function scoreForAttr(name: string): number {
    if (name === 'role' || name === 'aria-role') {
        return 5;
    }
    if (name === 'aria-label') {
        return 3;
    }
    return 1;
}

const TERM_PENALTY = -1; // subtract 1 from score per additional term

function baseCandidates(element: HTMLElement): Candidate[] {
    const candidates: Candidate[] = [];

    // Tag candidate
    if (element.tagName) {
        const tagTerm: Term = {
            tag: element.tagName.toLowerCase()
        };
        candidates.push({
            terms: [tagTerm],
            topMatch: element,
            score: 1,
            matchCount: matchCount([tagTerm]),
        });
    }

    // ID candidate (usually unique and preferred)
    if (element.id) {
        const idTerm: Term = {
            id: element.id
        };
        candidates.push({
            terms: [idTerm],
            topMatch: element,
            score: 10, // Higher score for ID selectors
            matchCount: matchCount([idTerm]),
        });
    }

    // Class candidates (add one candidate per class)
    if (element.classList && element.classList.length > 0) {
        Array.from(element.classList).forEach(className => {
            const classTerm: Term = {
                className: className
            };
            candidates.push({
                terms: [classTerm],
                topMatch: element,
                score: 3 + scoreForClassName(className),
                matchCount: matchCount([classTerm]),
            });
        });
    }

    // Attribute candidates
    if (element.attributes && element.attributes.length > 0) {
        Array.from(element.attributes)
            .filter(attr => attr.name !== 'id' && attr.name !== 'class') // Skip id and class as they're handled above
            .forEach(attr => {
                // Create a term with just the attribute presence
                const attrTerm: Term = {
                    hasAttr: attr.name
                };
                candidates.push({
                    terms: [attrTerm],
                    topMatch: element,
                    score: scoreForAttr(attr.name),
                    matchCount: matchCount([attrTerm]),
                });

                // Create a term with specific attribute value if it exists
                if (attr.value) {
                    const attrValTerm: Term = {
                        hasAttr: attr.name,
                        attrVal: attr.value
                    };
                    candidates.push({
                        terms: [attrValTerm],
                        topMatch: element,
                        score: scoreForAttr(attr.name) + 1, // Extra point for value specificity
                        matchCount: matchCount([attrValTerm]),
                    });
                }
            });
    }

    return candidates;
}

function reduceCandidateCount(cands: Candidate[]): Candidate[] {
    const maxMatchCount = 60;
    const keepCandidates = 40;
    const buckets = 10;
    const greatestMatchCount = cands.reduce((max, cand) => Math.max(max, cand.matchCount), 0);
    const bucketInterval = Math.ceil(greatestMatchCount / buckets);

    // Step 1: Filter out candidates with too many matches
    cands = cands.filter(x => x.matchCount <= maxMatchCount);
    if (cands.length <= keepCandidates) {
        return cands;
    }

    // Step 2: Group candidates into buckets based on their match count
    const bucketsArray: Candidate[][] = Array(buckets).fill(null).map(() => []);

    cands.forEach(candidate => {
        // Calculate which bucket this candidate belongs to
        const bucketIndex = Math.min(buckets - 1, Math.floor(candidate.matchCount / bucketInterval));
        bucketsArray[bucketIndex].push(candidate);
    });

    // Step 3: Sort each bucket by score (higher scores first)
    bucketsArray.forEach(bucket => {
        bucket.sort((a, b) => b.score - a.score);
    });

    // Step 4: Calculate how many candidates to keep from each bucket
    const itemsPerBucket = Math.ceil(keepCandidates / buckets);

    // Step 5: Select top candidates from each bucket
    const result: Candidate[] = [];
    bucketsArray.forEach(bucket => {
        result.push(...bucket.slice(0, itemsPerBucket));
    });

    // Step 6: If we have too many candidates, sort by score and only keep the top ones
    if (result.length > keepCandidates) {
        result.sort((a, b) => b.score - a.score);
        return result.slice(0, keepCandidates);
    }

    return result;
}

const DEBUG = true;

function expandCandidate(candidate: Candidate, seenSelectorsToSkip: {[id: string]: true}, origElement: HTMLElement): Candidate[] {
    const result: Candidate[] = [];
    const currentElement = candidate.topMatch as HTMLElement;

    // 1. Walk up parent chain (up to 3 levels)
    const parents: HTMLElement[] = [];
    let parent = currentElement.parentElement;

    for (let i = 0; i < 3; i++) {
        if (!parent) break;
        parents.push(parent);
        if (parent.tagName === 'BODY') { break; }
        parent = parent.parentElement;
    }

    // Process each parent level
    for (let i = 0; i < parents.length; i++) {
        const currentParent = parents[i];
        const parentCandidates = baseCandidates(currentParent);

        // Create new candidates by combining parent with current candidate
        for (const parentCandidate of parentCandidates) {
            // Mark as a direct child if it's the immediate parent
            const newCandidate: Candidate = {
                terms: [...parentCandidate.terms, ...candidate.terms],
                topMatch: currentParent,
                score: candidate.score + parentCandidate.score + TERM_PENALTY, // penalty for additional term
                matchCount: -1,
            };
            if (i === 0) {
                // only the first parent is a direct child
                newCandidate.terms[1] = {...newCandidate.terms[1], directChild: true};
            }
            newCandidate.matchCount = matchCount(newCandidate.terms);

            const selector = candidateToString(newCandidate);
            if (!seenSelectorsToSkip[selector]) {
                seenSelectorsToSkip[selector] = true;
                result.push(newCandidate);
            }

            if (DEBUG) {
                assertCandidateMatches(selector, origElement);
            }
        }
    }

    // 2. Add nth-child or last-child if applicable
    const addPositionalCandidate = (term: Term): void => {
        const newCandidate: Candidate = {
            terms: [...candidate.terms],
            topMatch: candidate.topMatch,
            score: candidate.score + 2, // Positional selectors are good
            matchCount: -1,
        };

        newCandidate.matchCount = matchCount(newCandidate.terms);

        const selector = candidateToString(newCandidate);
        if (!seenSelectorsToSkip[selector]) {
            seenSelectorsToSkip[selector] = true;
            result.push(newCandidate);
        }
        if (DEBUG) {
            assertCandidateMatches(selector, origElement);
        }
    };

    // Add nth-child if the element has siblings
    if (currentElement.parentElement) {
        const siblings = Array.from(currentElement.parentElement.children);
        const index = siblings.indexOf(currentElement);

        if (index !== -1) {
            // Add nth-child (1-based index)
            const nthChildTerm: Term = {
                ...candidate.terms[0],
                nthChild: index + 1
            };
            addPositionalCandidate(nthChildTerm);

            // Add last-child if it's the last child
            if (index === siblings.length - 1) {
                const lastChildTerm: Term = {
                    ...candidate.terms[0],
                    lastChild: true
                };
                addPositionalCandidate(lastChildTerm);
            }
        }
    }

    // // 3. Walk down into children (up to 2 levels)
    // const addChildCandidates = (element: HTMLElement, depth: number, maxDepth: number,
    //                            parentTerms: Term[] = []): void => {
    //     if (depth > maxDepth) return;

    //     // Process children
    //     for (let i = 0; i < element.children.length; i++) {
    //         const child = element.children[i] as HTMLElement;

    //         // Get basic candidates for this child
    //         const childCandidates = baseCandidates(child);

    //         for (const childCandidate of childCandidates) {
    //             // Create a child term with direct descendant marker
    //             const childTerm: Term = {
    //                 ...childCandidate.term,
    //                 directChild: true
    //             };

    //             // Create the new candidate combining the current path with this child
    //             const newParentTerms = [...candidate.parentTerms, candidate.term, ...parentTerms];
    //             const newCandidate: Candidate = {
    //                 term: childTerm,
    //                 parentTerms: newParentTerms,
    //                 topMatch: candidate.topMatch,
    //                 score: candidate.score + childCandidate.score + TERM_PENALTY * 2, // higher penalty for going down
    //                 matchCount: matchCount([...newParentTerms, childTerm]),
    //                 expandedYet: false
    //             };

    //             const selector = candidateToString(newCandidate);
    //             if (!seenSelectorsToSkip[selector]) {
    //                 seenSelectorsToSkip[selector] = true;
    //                 result.push(newCandidate);
    //             }
    //         }

    //         // Recurse for deeper levels
    //         if (depth < maxDepth) {
    //             const newParentTerm: Term = {
    //                 tag: child.tagName.toLowerCase(),
    //                 directChild: true
    //             };
    //             addChildCandidates(child, depth + 1, maxDepth, [...parentTerms, newParentTerm]);
    //         }
    //     }
    // };

    // // Start walking down from the current element (max depth 2)
    // addChildCandidates(currentElement, 1, 2);

    return result;
}

function printCandidates(candidates: Candidate[]): void {
    // print count and selector, in order of count
    const sortedCandidates = candidates.sort((a, b) => b.matchCount - a.matchCount);
    sortedCandidates.forEach(candidate => {
        const selector = candidateToString(candidate);
        console.log(`Selector: ${selector}, Match Count: ${candidate.matchCount}, Score: ${candidate.score}`);
    });
}

export function generateSelectorList(element: HTMLElement): string[] {
    const iterationCount = 3;
    
    let pool = reduceCandidateCount(baseCandidates(element));
    if (DEBUG) {
        console.log("BASE CANDIDATES:");
        printCandidates(pool);
    }
    const seen: {[id: string]: true} = {};
    pool.forEach(c => {
        const sel = candidateToString(c);
        seen[sel] = true;
    });

    const expandedIds: {[id: string]: true} = {};

    for (let i = 0; i < iterationCount; i++) {
        const nextPool: Candidate[] = [...pool];
        for (const candidate of pool) {
            const id = candidateToString(candidate);
            if (expandedIds[id]) { continue; }
            expandedIds[id] = true;
            const expansions = expandCandidate(candidate, seen, element); // will be unseen
            nextPool.push(...expansions);
        }
        pool = reduceCandidateCount(nextPool);
        if (DEBUG) {
            console.log(`EXPANDED CANDIDATES (iteration ${i + 1}):`);
            printCandidates(pool);
        }
    }
    return pool.map(x => candidateToString(x));
}

function assertCandidateMatches(selector: string, origElement: HTMLElement): void {
    const matches = document.querySelectorAll(selector);
    const found = Array.from(matches).some((el: Element) => el === origElement);
    if (!found) {
        // throw
        throw new Error(`Selector ${selector} does not match the original element.`);
    }
}
