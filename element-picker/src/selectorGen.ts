
// Our candidates have at most 3 terms
interface Candidate {
    term: Term;
    parentTerms: Term[]; // first is highest in the tree
    // hasTerms: Term[]; // for :has selectors; Do not implement yet

    topMatch: HTMLElement // the element corresponding to the highest parent we've traversed (or self)

    score: number; // higher is better. Bump the score for good terms; reduce it for bad terms
    matchCount: number;
    expandedYet: boolean;
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
    // TODO
}

function candidateToString(cand: Candidate): string {
    const allTerms = [...cand.parentTerms, cand.term];
    return allTerms.join(' ');
}

function matchCount(terms: Term[]): number {
    let sel = terms.map(t => termToString(t)).join(' ');
    return document.querySelectorAll(sel).length;
}

function scoreForClassName(className: string): number {
    // gibberish classes detract from score; non-gibberish classes increase it
    // TODO: implement gibberish detection
    return 0;
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
    // TODO: return candidates for tag name, any classes, ids, attrs
}

function reduceCandidateCount(cands: Candidate[]): Candidate[] {
    const maxMatchCount = 60;
    const keepCandidates = 40;
    const buckets = 10;
    const greatestMatchCount = // TODO
    const bucketInterval = Math.ceil(greatestMatchCount / buckets);

    cands = cands.filter(x => x.matchCount <= maxMatchCount);
    if (cands.length < keepCandidates) {
        return cands;
    }

    // TODO: filter out items with >60 matches, then bucket them into N buckets, then keep the highest keepCandidates / bucketCount items based on score
    // then return
}

function expandCandidate(candidate: Candidate, seenSelectorsToSkip: {[id: string]: true}): Candidate[] {
    // TODO: Expand our candidate set by:
    // 1. walking up one, two or three levels in the parentage and adding the baseCandidates from this parent
    // 2. adding an nth-child or last-child tag if applicable
    // 3. walk up to one or two levels DOWN into the children of the element
    // Return all the new candidates, but ONLY if htey're not in seenSelectorsToSkip. Also add them to seenSelectorsToSkip 
}

export function generateSelectorList(element: HTMLElement): string[] {
    const iterationCount = 3;
    
    let pool = reduceCandidateCount(baseCandidates(element));
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
            const expansions = expandCandidate(candidate, seen); // will be unseen
            nextPool.push(...expansions);
        }
        pool = reduceCandidateCount(nextPool);
    }
    return pool
}
