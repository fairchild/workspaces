# GraphQL Query Reference for gh-discuss

Raw queries used by `gh-discuss.py`. Useful for debugging or extending.

## Get Repo ID + Discussion Categories

```graphql
{
  repository(owner: "$OWNER", name: "$NAME") {
    id
    discussionCategories(first: 10) {
      nodes { id name slug }
    }
  }
}
```

## List Open Discussions by Category

```graphql
{
  repository(owner: "$OWNER", name: "$NAME") {
    discussions(first: 50, categoryId: "$CATEGORY_ID", states: OPEN) {
      nodes {
        id number title body closed
        author { login }
        labels(first: 10) { nodes { name } }
        comments(first: 1) { totalCount }
        createdAt
      }
    }
  }
}
```

## Get Single Discussion with Comments

```graphql
{
  repository(owner: "$OWNER", name: "$NAME") {
    discussion(number: $NUMBER) {
      id number title body closed
      category { name }
      author { login }
      labels(first: 10) { nodes { id name } }
      answer { id body author { login } }
      comments(first: 50) {
        nodes {
          id body
          author { login }
          createdAt
        }
      }
    }
  }
}
```

## Create Discussion

```graphql
mutation {
  createDiscussion(input: {
    repositoryId: "$REPO_ID"
    categoryId: "$CATEGORY_ID"
    title: "$TITLE"
    body: "$BODY"
  }) {
    discussion { id number url }
  }
}
```

## Add Comment

```graphql
mutation {
  addDiscussionComment(input: {
    discussionId: "$DISCUSSION_ID"
    body: "$BODY"
  }) {
    comment { id url }
  }
}
```

## Update Discussion (title/body/category)

```graphql
mutation {
  updateDiscussion(input: {
    discussionId: "$DISCUSSION_ID"
    title: "$NEW_TITLE"
  }) {
    discussion { id title }
  }
}
```

## Close Discussion

```graphql
mutation {
  closeDiscussion(input: {
    discussionId: "$DISCUSSION_ID"
    reason: RESOLVED
  }) {
    discussion { id closed }
  }
}
```

## Reopen Discussion

```graphql
mutation {
  reopenDiscussion(input: {
    discussionId: "$DISCUSSION_ID"
  }) {
    discussion { id closed }
  }
}
```

## Mark Answer (Q&A only)

```graphql
mutation {
  markDiscussionCommentAsAnswer(input: {
    id: "$COMMENT_ID"
  }) {
    discussion { id isAnswered }
  }
}
```

## Add Labels

First get label IDs:
```graphql
{
  repository(owner: "$OWNER", name: "$NAME") {
    labels(first: 20) {
      nodes { id name }
    }
  }
}
```

Then add to discussion:
```graphql
mutation {
  addLabelsToLabelable(input: {
    labelableId: "$DISCUSSION_ID"
    labelIds: ["$LABEL_ID"]
  }) {
    labelable { ... on Discussion { id } }
  }
}
```

## Remove Labels

```graphql
mutation {
  removeLabelsFromLabelable(input: {
    labelableId: "$DISCUSSION_ID"
    labelIds: ["$LABEL_ID"]
  }) {
    labelable { ... on Discussion { id } }
  }
}
```
