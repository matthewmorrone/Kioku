// Wire types mirroring the Swift bridge's BridgeNotePayloads. Kept in lockstep
// with Kioku/Bridge/BridgeNotePayloads.swift — when one changes, update both.

export interface BridgeNoteSummary {
  id: string;
  title: string;
  modifiedAt: string;
  createdAt: string;
  segmentCount: number;
  hasAudio: boolean;
}

export interface BridgeNoteDetail {
  id: string;
  title: string;
  content: string;
  createdAt: string;
  modifiedAt: string;
  segments: BridgeSegment[] | null;
}

export interface BridgeSegment {
  surface: string;
  furigana: BridgeFurigana[] | null;
}

export interface BridgeFurigana {
  start: number;
  end: number;
  reading: string;
}

export interface BridgeNoteListResponse {
  notes: BridgeNoteSummary[];
}

export interface BridgeSegmentsResponse {
  segments: BridgeSegment[];
}
