'use strict';

class Tunesmith.Models.PitchDetectorModel extends Backbone.Model

  initialize: (cb, context) ->
    @set "pitch", new PitchAnalyzer(44100);
    @set "context", context

    cb()

  getNote: (frequency) ->
    if (frequency)
      Math.round(69 + 12 * Math.log(frequency / 440) / Math.LN2)
    else
      0

  chunk: (buffer, tempo, minInterval) ->
    chunkLength = Math.round(2646000 / minInterval / tempo)
    end = buffer.length - chunkLength;
    (buffer.subarray(x, x + chunkLength) for x in [0..end] by chunkLength)

  convertToPitches: (chunks) ->
    pitches = []
    pitch = @get 'pitch'
    YIN = makeYIN({bufferLength: chunks[0].length})
    for chunk in chunks
      YINTone = YIN.getPitch(chunk)
      ac_tone = detectPitch(chunk)
      pitch.input(chunk)
      pitch.process()
      tone = pitch.findTone() or {freq: 0, db: -90}
      pitches.push {pitch: @getNote((tone.freq)), vel: 2*(tone.db + 90), len: 1, ac: @getNote(ac_tone)}
    pitches

  convertToDrumPitches: (chunks) ->
    pitches = []
    for chunk in chunks
      chunk = chunk.subarray(0, @nextPowerOf2(chunk.length)/2)
      fft = new FFT.complex(chunk.length, false)
      fft_results = new Float32Array(chunk.length * 2)
      fft.simple(fft_results, chunk, 'real')

      results = []
      for val, i in fft_results
        if ((i % 2) && (i < fft_results.length/2))
          val2 = fft_results[i - 1]
          mag = Math.sqrt(val * val + val2 * val2)

          if results[Math.floor(30*i/fft_results.length)]
            results[Math.floor(30*i/fft_results.length)] += mag
          else
            results[Math.floor(30*i/fft_results.length)] = mag

      results = results.slice(0, 8)
      max = 0;
      max_idx = 0;
      for result, i in results
        results[i] = Math.floor(result/200)
        if results[i] > max
          max = results[i]
          max_idx = i

      sum = 0;
      (sum += result for result in results)

      note = {pitch: 0, vel: 0, len: 1}
      if sum > 1
        if max_idx == 0
          console.log "kick"
          note = {pitch: 1, vel: Math.min(127, 4*sum), len: 4}
        if sum > 20 and (max_idx == 1 or max_idx == 2 or max_idx == 3 or max_idx == 4)
          console.log "snare"
          note = {pitch: 2, vel: Math.min(sum, 127), len: 4}
        if results[0] < 5 and max_idx > 3
          console.log "hat"
          note = {pitch: 3, vel: Math.min(sum, 127), len: 4}
      pitches.push(note)
    pitches

  merge: (notes) ->
    sustained = notes[0]
    for note, i in notes
      next = notes[i+1]
      dnext = notes[i+2]
      if sustained and (sustained.pitch > 0) and (note.ac > 20) and (note.pitch == 0)
        note.pitch = sustained.pitch

      if next and (sustained.pitch > 0) and (sustained.pitch == next.pitch)
        note.pitch = sustained.pitch

      if next and (15 > note.pitch - sustained.pitch > 7) and (15 > note.pitch - next.pitch > 7) and (15 > note.pitch - dnext.pitch > 7)
        note.pitch -= 12

      if next and dnext and (Math.abs(note.pitch - next.pitch) == 1) and (Math.abs(note.pitch - dnext.pitch) == 1)
        note.pitch = next.pitch

      if note.pitch == sustained.pitch
        note.pitch = 0
        sustained.len++

      if note.pitch != sustained and note.pitch != 0
        sustained = note
    notes

  mergeDrums: (notes) ->
    for note, i in notes
      prev = notes[i-1]
      if prev and prev.pitch == note.pitch
        threshold = if note.pitch == 2 then 2 else 5/4
        if prev.vel > threshold*note.vel
          note.pitch = 0
          note.vel = 0
        else if prev.vel*threshold < note.vel
          prev.pitch = 0
          prev.vel = 0
    notes


  standardizeClipLength: (notes, minInterval) ->
    len = notes.length
    prevPowerOf2 = @nextPowerOf2(len)/2
    nextPowerOf2 = @nextPowerOf2(len)

    if (len - prevPowerOf2) < minInterval
      notes = notes.slice(0, prevPowerOf2)
    else
      while (notes.length < nextPowerOf2)
        notes.push({pitch:0, vel: 0, len: 1})

    notes

  convertToDrums: (buffer, tempo, minInterval) ->
    chunks = @chunk(buffer, tempo, minInterval)
    drumPitches = @convertToDrumPitches(chunks)
    merged = @mergeDrums(drumPitches)
    stdzd = @standardizeClipLength(merged, minInterval)
    console.log stdzd
    return stdzd

  convertToNotes: (buffer, tempo, minInterval) ->
    chunks = @chunk(buffer, tempo, minInterval)
    pitches = @convertToPitches(chunks)
    merged = @merge(pitches)
    stdzd = @standardizeClipLength(merged, minInterval)
    return stdzd

  nextPowerOf2: (n) ->
    n--
    n |= n >> 1
    n |= n >> 2
    n |= n >> 4
    n |= n >> 8
    n |= n >> 16
    n++