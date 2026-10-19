/**
 * The texts the chat shows while a message waits for its reply. Generic on purpose: they never
 * name the assistant's product. The plain lines say what is happening; a light line is mixed in
 * between them, in an order that changes per message (the seed).
 */

/** Sent, no reply yet. */
export const WAITING = ["Sending your message...", "Waiting for the reply...", "Thinking it over..."];

/** The reply is coming in. */
export const WRITING = ["Writing the reply...", "Receiving the reply..."];

export const FUNNY_WAITING = [
  "Warming up the neurons...",
  "Consulting the rubber duck...",
  "Counting the brackets twice...",
  "Asking very nicely...",
  "Brewing a fresh pot of ideas...",
  "Reticulating splines...",
  "Herding semicolons...",
  "Untangling the spaghetti...",
  "Reading the manual, for once...",
  "Bribing the compiler with cookies...",
  "Looking for the missing semicolon...",
  "Turning it off and on again...",
  "Feeding the hamsters...",
  "Rearranging the bits...",
  "Biting the bits...",
  "Pretending this is a hard one...",
  "Checking under the sofa for bugs...",
  "Sharpening the pencils...",
  "Polishing the curly braces...",
  "Asking the senior developer (a cat)...",
  "Finding where the bug moved to...",
  "Reading the error message, all of it...",
  "Adjusting the tabs versus spaces dial...",
  "Untying the knots in the CSS...",
  "Negotiating with the cache...",
  "Searching Stack Overflow from memory...",
  "Waking up the build server...",
  "Counting to infinity, twice...",
  "Measuring twice, cutting once...",
  "Persuading the pixels to line up...",
  "Making a to-do list for the to-do list...",
  "Looking busy...",
  "Shuffling the deck of ideas...",
  "Consulting the ancient scrolls (the docs)...",
  "Proofreading the zeros and ones...",
  "Calming down a nervous regex...",
  "Giving the variables better names...",
  "Putting on the bunny suit...",
  "Waiting for the cleanroom air shower...",
  "Aligning the reticle, nanometer by nanometer...",
  "Exposing the wafer to some bright ideas...",
  "Coating the photoresist evenly...",
  "Focusing the extreme ultraviolet light...",
  "Checking the overlay, then checking it again...",
  "Tuning the dose and the focus...",
  "Etching the details in...",
  "Doping the silicon, legally...",
  "Polishing the wafer to a mirror shine...",
  "Keeping Moore's law on schedule...",
  "Shrinking the problem to 2 nanometers...",
  "Counting the dies per wafer...",
  "Asking the particle counter for good news...",
  "Waiting for the stage to settle...",
  "Calibrating the mirrors, very carefully...",
  "Measuring the critical dimension...",
  "Loading the wafer onto the stage...",
  "Cackling over the bubbling beakers...",
  "Pulling the big lever...",
  "Waiting for the lightning to strike...",
  "It's alive! Almost...",
  "Adjusting the goggles...",
  "Charging the Tesla coils...",
  "Consulting the lab notebook (mostly scribbles)...",
  "Adding a dash of something glowing...",
  "Mixing the blue one with the green one...",
  "Rewiring the brain in a jar...",
  "Calibrating the death ray (for bugs only)...",
  "Asking Fritz to fetch the documentation...",
  "Turning it up to eleven thousand volts...",
  "Counting the a's in banana. Three. Probably...",
  "Counting the r's in strawberry, slowly this time...",
  "Counting the words in this sentence (it is eight)...",
  "Counting the fingers on the hand. Still five...",
  "Deciding whether to walk or drive to the car wash...",
  "Remembering to bring the car to the car wash...",
  "Checking whether 9.11 is bigger than 9.9 (it is not)...",
  "Weighing a kilo of feathers against a kilo of bricks...",
  "Getting the wolf, the goat and the cabbage across the river...",
  "Working out how many sisters Alice's brother has...",
  "Solving the Tower of Hanoi, one disc at a time...",
  "Looking for the seahorse emoji (there isn't one)...",
  "Drawing a pelican riding a bicycle...",
  "Reading the time off an analogue clock, carefully...",
];

export const FUNNY_WRITING = [
  "Typing furiously...",
  "Choosing the finest characters...",
  "Indenting with care...",
  "Words incoming...",
  "Closing every bracket it opens...",
  "Dotting the i's, crossing the t's...",
  "Making it look easy...",
  "Putting the commas where they belong...",
  "Writing it in pencil first...",
  "Spell-checking the semicolons...",
  "Adding a sprinkle of whitespace...",
  "Lining up the indents like ducklings...",
  "Hold on, it is getting good...",
  "Wrapping it up with a bow...",
  "Almost there, probably...",
  "Printing the layers, one by one...",
  "Developing the resist...",
  "Raising the yield, line by line...",
  "Dicing the answer into neat chips...",
  "Running the final inspection...",
  "The experiment is working! Probably...",
  "Stitching the parts together...",
  "Bottling the results...",
  "Writing it down before it escapes...",
  "Chiseling the code...",
  "Writing the answer, then counting the r's again...",
];

/** Light lines while Copilot works on how something looks (a look request, or a reply writing styles). */
export const FUNNY_VISUAL = [
  "Mixing the paint...",
  "Choosing between forty shades of grey...",
  "Stepping back to look at the canvas...",
  "Squinting like an art critic...",
  "Cleaning the brushes...",
  "Adding a happy little tree...",
  "Painting outside the lines, then tidying up...",
  "Giving it a Mona Lisa smile...",
  "Framing it nicely...",
  "Nudging it one pixel to the left...",
  "Nudging it back one pixel to the right...",
  "Picking a colour, then picking it again...",
  "Applying a fresh coat of CSS...",
  "Sketching it in pencil first...",
  "Holding up the colour swatches...",
  "Rounding the corners, gently...",
  "Looking for the golden ratio...",
  "Centring the div, the hardest problem in art...",
  "Letting the paint dry...",
  "Adding a little more white space...",
  "Consulting the colour wheel...",
  "Debating the kerning...",
  "Hanging it straight on the wall...",
  "Waiting for the muse...",
  "Adjusting the lighting in the gallery...",
  "Letting the margins breathe...",
  "Putting on the beret...",
  "Dipping the brush in the gradient...",
];

/** A reply that is writing or editing a stylesheet: visual work, whatever the request said. */
export function writesStyles(progress: string): boolean {
  return /ACTION\s+(write|edit)\s+\S+\.(css|scss|sass|less|styl)\b/i.test(progress);
}

/** Light lines for StreamHub's own work (the activity kind), mixed in after the plain status line. */
export const FUNNY_ACTIVITY: Record<string, string[]> = {
  newchat: [
    "Clearing the whiteboard...",
    "Fresh page, fresh coffee...",
    "Sweeping up the old conversation...",
    "Rolling out a clean wafer...",
    "Opening a new lab notebook...",
    "Wiping the slate clean...",
    "Filing the old chat away...",
    "Starting over, with feeling...",
  ],
  page: [
    "Squinting at the pixels...",
    "Holding the page up to the light...",
    "Checking the page under the microscope...",
    "Looking for things out of place...",
    "Inspecting the layout for particles...",
    "Measuring the margins with a ruler...",
    "Making sure the buttons line up...",
    "Counting the pixels, one by one...",
    "Making sure the pelican stays on the bicycle...",
  ],
  syntax: [
    "Counting the brackets, again...",
    "Asking the parser nicely...",
    "Looking for a stray comma...",
    "Proofreading in machine language...",
    "Matching every opening with a closing...",
    "Making sure every quote comes back...",
    "Reading it the way a computer would...",
    "Untangling the parentheses...",
    "Checking 9.9 and 9.11 are in the right order...",
  ],
  tests: [
    "Poking it with a stick...",
    "Crossing fingers, running tests...",
    "Pushing all the buttons...",
    "Putting it through the wringer...",
    "Testing it on the lab rats...",
    "Kicking the tyres...",
    "Running the experiment again, for science...",
    "Asking the tests how they feel...",
    "Passing the Turing test, then the unit tests...",
    "Asking the tests how many r's are in strawberry...",
  ],
  index: [
    "Looking under every file...",
    "Dusting the corners...",
    "Taking inventory...",
    "Labelling the jars on the shelf...",
    "Drawing a map of the project...",
    "Writing the card catalogue...",
    "Sorting the drawers...",
    "Counting the files, then counting them again...",
    "Making a list, reading it twice...",
  ],
  wait: [
    "Letting Copilot catch its breath...",
    "Making a cup of tea while we wait...",
    "Counting sheep...",
    "Waiting for the cleanroom to settle...",
    "Twiddling thumbs, professionally...",
    "Watching the kettle (it never boils)...",
    "Reading the waiting room magazines...",
    "Humming the hold music...",
  ],
  agent: [
    "Reading the whole library...",
    "Taking very thorough notes...",
    "Following every footnote...",
    "Asking the experts...",
    "Pulling books off the top shelf...",
    "Cross-referencing the cross-references...",
    "Underlining the important bits...",
    "Checking the sources twice...",
  ],
  busy: [
    "Still stirring the cauldron...",
    "Good things take time...",
    "Copilot is on a roll, give it a moment...",
    "Still thinking, deeply...",
    "The beakers are still fizzing...",
    "Letting the experiment run its course...",
    "Patience is part of the recipe...",
    "Still bubbling away...",
  ],
  convert: [
    "Lining up the columns...",
    "Counting the rows...",
    "Telling the numbers from the text...",
    "Working out which columns are dates...",
    "Reading every cell, politely...",
    "Tidying up the headers...",
    "Turning cells into rows...",
    "Smoothing out the spreadsheet...",
  ],
  install: [
    "Unpacking the boxes...",
    "Fetching the parts from the shelf...",
    "Reading the assembly instructions...",
    "Checking every part is in the box...",
    "Tightening the last screws...",
    "Stacking the packages neatly...",
  ],
  download: [
    "Carrying the file over...",
    "Bringing it in, byte by byte...",
    "Signing for the delivery...",
    "Unwrapping the file...",
    "Checking the parcel arrived in one piece...",
    "Holding the door for the file...",
  ],
};

/** A fixed shuffle for one seed (the same message keeps the same order while it waits). */
export function shuffled<T>(list: readonly T[], seed: number): T[] {
  const out = [...list];
  let s = (Math.abs(Math.floor(seed)) % 2147483646) + 1;
  for (let i = out.length - 1; i > 0; i--) {
    s = (s * 16807) % 2147483647;
    const j = s % (i + 1);
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

/** StreamHub's own work: the plain status line first, then it and the kind's light lines taking turns. */
export function activityTexts(plain: string, kind: string | undefined, seed: number): string[] {
  const funny = shuffled(FUNNY_ACTIVITY[kind ?? ""] ?? [], seed);
  const out = [plain];
  for (const f of funny) out.push(f, plain);
  return out;
}

/** Plain lines first, then plain and light lines taking turns (art lines for visual work). */
export function thinkingTexts(phase: "waiting" | "writing", seed: number, visual = false): string[] {
  const plain = phase === "writing" ? WRITING : WAITING;
  const funny = shuffled(visual ? FUNNY_VISUAL : phase === "writing" ? FUNNY_WRITING : FUNNY_WAITING, seed);
  const out = [...plain];
  funny.forEach((f, i) => out.push(f, plain[i % plain.length]));
  return out;
}
