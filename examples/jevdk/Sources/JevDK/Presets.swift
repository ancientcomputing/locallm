import OpenJevKit

/// Starting points, taken from the question sets the SDK's OpenJev evaluation measured. The wordings
/// are the best-scoring variants on Qwen3-4B-4bit as of 2026-10-03.
enum Presets {
    struct Preset: Identifiable {
        var id: String { self.set.name }
        let set: QuestionSet
        let input: String
        let batch: String
        /// One-click sample inputs for single-input mode: (chip label, text).
        var samples: [(String, String)] = []
    }

    /// A preset built from named samples: the first is the input, all of them are the batch.
    static func scenario(_ set: QuestionSet, _ samples: [(String, String)]) -> Preset {
        Preset(set: set, input: samples[0].1, batch: samples.map(\.1).joined(separator: "\n"), samples: samples)
    }

    static let all: [Preset] = [
        Preset(set: triage, input: triageInput, batch: triageBatch),
        Preset(set: tools, input: "Will I need an umbrella in Boston this afternoon?", batch: toolsBatch),
        Preset(set: answerCheck, input: "Question: What is the capital of Australia?\nAnswer: Sydney.", batch: answerCheckBatch),
        scenario(support, supportSamples),
        scenario(reviews, reviewSamples),
        scenario(moderation, moderationSamples),
        Preset(set: QuestionSet(name: "Blank", system: QuestionSet.defaultSystem, questions: []), input: "", batch: ""),
    ]

    // MARK: Router triage

    static let triage = QuestionSet(
        name: "Router triage",
        // Exactly the evaluation's triage system prompt, so results match it.
        system: """
            You are a classifier. Read the user's request and answer one multiple-choice question about it. \
            Reply with the answer label only, nothing else.
            """,
        inputLabel: "Request",
        questions: [
            EditableQuestion(name: "needsLiveData", kind: .noul, text: "Does this user query need live data?"),
            EditableQuestion(name: "kind", kind: .choice, text: "Which category fits this request best?", options: [
                AnswerOption(key: "factual", description: "a question about facts, how something works, or advice"),
                AnswerOption(key: "code", description: "writing, fixing or explaining code or software"),
                AnswerOption(key: "math", description: "a calculation, equation or proof"),
                AnswerOption(key: "creative", description: "a writing or language task (stories, poems, emails, rewriting, summarising, translating)"),
                AnswerOption(key: "chitchat", description: "small talk or social conversation, no real task"),
            ]),
            EditableQuestion(name: "sensitive", kind: .noul,
                             text: "Does the request contain personal or private information about the user or another person?"),
            EditableQuestion(name: "depth", kind: .score, text: "How much reasoning does answering this need?", options: [
                AnswerOption(key: "0", description: "none (recall or rewrite)"),
                AnswerOption(key: "1", description: "a little"),
                AnswerOption(key: "2", description: "multi-step"),
                AnswerOption(key: "3", description: "deep (hard problem)"),
            ]),
        ])

    static let triageInput = "Who won last night's NBA game between the Lakers and the Celtics?"

    static let triageBatch = """
        What is the capital of Australia?
        Who won last night's NBA game between the Lakers and the Celtics?
        What's the current price of Bitcoin?
        What's the population of Tokyo?
        Write a Swift function that merges two sorted arrays in O(n).
        Prove that the square root of 2 is irrational.
        Write a haiku about the first snow.
        Summarize this in one sentence: "The committee agreed to raise park funding by 10%."
        My blood test says my ALT is 85 U/L. Is that bad?
        What is the normal range for ALT in a blood test?
        hey, how's it going?
        When did the Berlin Wall fall?
        """

    // MARK: Tool choice

    static let tools = QuestionSet(
        name: "Tool choice",
        system: """
            You are a classifier. Read the user's request and answer one multiple-choice question about it. \
            Reply with the answer label only, nothing else.

            The assistant has these tools:
            - calendar: read, create or change events in the user's calendar
            - weather: forecasts and current conditions for a place
            - web_search: search the web for current or niche information
            - files: search the user's own documents and files
            - calculator: exact arithmetic
            - none: answer directly without a tool
            """,
        inputLabel: "Request",
        questions: [
            EditableQuestion(name: "tool", kind: .choice, text: "Which tool should the assistant use first?", options: [
                AnswerOption(key: "calendar", description: "calendar"),
                AnswerOption(key: "weather", description: "weather"),
                AnswerOption(key: "web_search", description: "web_search"),
                AnswerOption(key: "files", description: "files"),
                AnswerOption(key: "calculator", description: "calculator"),
                AnswerOption(key: "none", description: "none"),
            ]),
        ])

    static let toolsBatch = """
        Schedule a dentist appointment for next Tuesday at 3pm.
        Will I need an umbrella in Boston this afternoon?
        Who won the Oscar for best picture this year?
        Find the PDF of my lease agreement.
        What is the capital of Peru?
        Compute the monthly payment on a $300,000 mortgage at 6.5% over 30 years.
        Summarize the causes of the French Revolution.
        """

    // MARK: Answer check

    static let answerCheck = QuestionSet(
        name: "Answer check",
        system: """
            You are a strict grader. Read the question and the proposed answer in the input, then \
            answer one yes/no question about them. Reply with Yes or No only.
            """,
        questions: [
            EditableQuestion(name: "complete", kind: .noul,
                             text: "Does the proposed answer fully and correctly address the question?"),
        ])

    static let answerCheckBatch = """
        Question: What is the capital of Australia? Answer: Canberra.
        Question: What is the capital of Australia? Answer: Sydney.
        Question: What's 17 × 23? Answer: 391.
        Question: What's 17 × 23? Answer: 381.
        Question: What's the weather in Seattle right now? Answer: I don't have access to live weather data.
        Question: List three causes of World War I. Answer: The assassination of Archduke Franz Ferdinand.
        """

    // MARK: Everyday triage (after Featherless's Simple Jev playground scenarios)
    //
    // Questions ask about what the text says ("explicitly asks for…", "mentions…"), so they can be
    // judged from the input alone.

    static let support = QuestionSet(
        name: "Customer support",
        system: """
            You are a classifier. Read the customer's message and answer one multiple-choice question \
            about it. Reply with the answer label only, nothing else.
            """,
        inputLabel: "Customer message",
        questions: [
            EditableQuestion(name: "team", kind: .choice, text: "Which team should handle this customer message?", options: [
                AnswerOption(key: "billing", description: "payments, invoices and refunds"),
                AnswerOption(key: "technical", description: "bugs, outages and product errors"),
                AnswerOption(key: "account", description: "profile, login and subscription changes"),
            ]),
            EditableQuestion(name: "urgent", kind: .noul,
                             text: "Is the customer blocked from using the product right now?"),
            EditableQuestion(name: "refund", kind: .noul, text: "Does the customer explicitly ask for money back?"),
            EditableQuestion(name: "angry", kind: .noul, text: "Is the customer angry or threatening to leave?"),
        ])

    static let supportSamples: [(String, String)] = [
        ("Double charge", "I see two charges for my Pro plan on this month's statement. Please refund one of them. Otherwise the app is great."),
        ("App outage", "Nothing loads since this morning, just a spinning wheel on every page. My whole team is stuck. What's going on?"),
        ("Account update", "How do I change the email address on my account? I'm moving to a new work address."),
        ("Cancel threat", "Third time this month the sync lost my files. If it happens again I'm cancelling and switching to a competitor."),
        ("Login trouble", "The password reset link says it has expired every time I click it, so I can't sign in."),
    ]

    static let reviews = QuestionSet(
        name: "Product reviews",
        system: """
            You are a classifier. Read the product review and answer one multiple-choice question about \
            it. Reply with the answer label only, nothing else.
            """,
        inputLabel: "Review",
        questions: [
            EditableQuestion(name: "sentiment", kind: .choice, text: "What is the overall sentiment of the review?", options: [
                AnswerOption(key: "positive", description: "mostly happy with the product"),
                AnswerOption(key: "mixed", description: "both real praise and real complaints"),
                AnswerOption(key: "negative", description: "mostly unhappy with the product"),
            ]),
            EditableQuestion(name: "topic", kind: .choice, text: "What does the review mainly talk about?", options: [
                AnswerOption(key: "quality", description: "how well the product works or how well it's made"),
                AnswerOption(key: "price", description: "price or value for money"),
                AnswerOption(key: "shipping", description: "delivery, packaging or arrival condition"),
                AnswerOption(key: "service", description: "customer service or returns"),
            ]),
            EditableQuestion(name: "defect", kind: .noul, text: "Does the reviewer report a broken or faulty item?"),
            EditableQuestion(name: "recommends", kind: .noul, text: "Does the reviewer say they would recommend it to others?"),
        ])

    static let reviewSamples: [(String, String)] = [
        ("Love it", "Best kettle I've owned. Boils fast, quiet, and looks great on the counter. Already bought one for my sister."),
        ("Broken on arrival", "Box was crushed and the glass lid arrived cracked. Waiting on a replacement."),
        ("Mixed", "Sound quality is excellent for the price, but the ear cushions started peeling after two months."),
        ("Pricey", "Works fine, nothing special. Not worth twice the price of the store brand."),
        ("Great support", "The blender died after a week, but support sent a new one within two days, no questions asked. Would recommend."),
    ]

    static let moderation = QuestionSet(
        name: "Community moderation",
        system: """
            You are a content moderator for a friendly gardening forum. Read the post and answer one \
            multiple-choice question about it. Reply with the answer label only, nothing else.
            """,
        inputLabel: "Post",
        questions: [
            EditableQuestion(name: "issue", kind: .choice, text: "This post was made on a gardening forum. Which problem, if any, does it have?", options: [
                AnswerOption(key: "none", description: "no problem, fine to publish"),
                AnswerOption(key: "harassment", description: "insults or attacks another member"),
                AnswerOption(key: "spam", description: "advertising, links to sell something, or repeated junk"),
                AnswerOption(key: "personalInfo", description: "shares someone's private contact details or address"),
                AnswerOption(key: "offTopic", description: "unrelated to gardening"),
            ]),
            EditableQuestion(name: "humanReview", kind: .noul,
                             text: "Is this post borderline enough that a human moderator should look at it?"),
        ])

    static let moderationSamples: [(String, String)] = [
        ("Helpful", "Tip for anyone struggling with seedlings: put a small fan on them for an hour a day. Stems got much sturdier."),
        ("Insult", "Only an idiot would water succulents every day. Did you even read the pinned post?"),
        ("Spam", "BEST garden tools 70% OFF!!! Click my profile link, today only!!!"),
        ("Doxxing", "The guy who sold me those bad seeds is Mark, he lives at 18 Oak Lane and his number is 555-0199."),
        ("Off topic", "Anyone watching the football tonight? Who do you think wins?"),
    ]
}

