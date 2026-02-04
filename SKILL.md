---
name: grab
version: 1.0.0
author: jamesalmeida
description: Download and archive content from URLs (tweets, YouTube videos). Saves media, text, transcripts, summaries, and thumbnails into organized folders in Dropbox for remote access.
when: "User shares a URL and wants to download/save/grab it, or asks to download a tweet video, YouTube video, or any media from a URL"
examples:
  - "grab this https://x.com/..."
  - "download this tweet"
  - "save this video"
  - "grab https://youtube.com/..."
tags:
  - download
  - media
  - twitter
  - youtube
  - transcript
  - archive
metadata:
  openclaw:
    emoji: "🫳"
    requires:
      bins:
        - yt-dlp
        - ffmpeg
---

# grab 🫳

Download and archive content from URLs into organized folders.

## What It Does

### Tweets (x.com / twitter.com)
- `tweet.txt` — tweet text, author, date, engagement stats
- `video.mp4` — attached video (if any)
- `image_01.jpg`, etc. — attached images (if any)
- `transcript.txt` — auto-transcribed from video (if video)
- `summary.txt` — AI summary of video (if video)
- Folder named by content description

### X Articles
- `article.txt` — full article text with title, author, date
- `summary.txt` — AI summary of article
- Requires Chrome browser relay (agent handles via browser snapshot)
- Script exits with code 2 and `ARTICLE_DETECTED:<id>:<url>` when it detects an article

### Reddit
- `post.txt` — title, author, subreddit, score, date, body text
- `comments.txt` — top comments with authors and scores
- `image_01.jpg`, etc. — attached images or gallery (if any)
- `video.mp4` — attached video (if any)
- `transcript.txt` — auto-transcribed from video (if video)
- `summary.txt` — AI summary of post + discussion
- If Reddit JSON API is blocked (exit code 3), agent uses OpenClaw managed browser to extract content (same as X articles)

### YouTube
- `video.mp4` — the video
- `description.txt` — video description
- `thumbnail.jpg` — video thumbnail
- `transcript.txt` — transcribed audio
- `summary.txt` — AI summary

## Output

All saves go to `~/Dropbox/Tersono Cloud/` with each download in its own folder:
```
~/Dropbox/Tersono Cloud/
  2026-02-03_tweet_embrace-change-you-can-shape-your-life/
    tweet.txt
    video.mp4
    transcript.txt
    summary.txt
  2026-02-03_youtube_how-to-build-an-ai-agent/
    video.mp4
    description.txt
    thumbnail.jpg
    transcript.txt
    summary.txt
```

## Usage

```bash
grab <url>
```

## Requirements

```bash
brew install yt-dlp ffmpeg
```

For transcription: needs `OPENAI_API_KEY` env var set.
