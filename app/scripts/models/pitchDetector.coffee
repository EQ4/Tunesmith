'use strict';

class Tunesmith.Models.PitchDetectorModel extends Backbone.Model

  initialize: (cb, context) ->
    @set "context", context
    cb()

  getNote: (frequency) ->
    if (frequency)
      Math.round(69 + 12 * Math.log(frequency / 440) / Math.LN2)
    else
      0

  chunk: (buffer, tempo, minInterval, chunkingFactor) ->
    chunkLength = Math.round(2646000 / (minInterval * tempo * chunkingFactor))
    end = buffer.length - chunkLength;
    (buffer.subarray(x, x + chunkLength) for x in [0..end] by chunkLength)

  convertToPitches: (chunks, chunkingFactor) ->
    pitches = []
    chunkLength = chunks[0].length
    YINDetector = YIN({butterLength: chunkLength})
    toneAVG = 0
    toneAVGcount = 0
    chunkCount = 0
    for chunk, i in chunks
      chunkCount++
      tone = YINDetector(chunk).freq
      if (0 < tone < 5000)
        toneAVG += tone * (1 + chunkingFactor - chunkCount)
        toneAVGcount += (1 + chunkingFactor - chunkCount)
      if chunkCount == chunkingFactor
        if toneAVGcount >= (chunkingFactor - 1)
          toneAVG /= toneAVGcount
          pitches.push({pitch: @getNote(toneAVG), vel: 128, len: 1})
        else
          pitches.push({pitch: 0, vel: 0, len: 1, ac: 0})
        toneAVG = 0
        toneAVGcount = 0
        chunkCount = 0
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

      # console.log results

      sum = 0;
      (sum += result for result in results)

      note = {pitch: 0, vel: 0, len: 1}
      if sum > 1
        if max_idx == 0
          # console.log "kick"
          note = {pitch: 1, vel: Math.min(110, 4*sum), len: 4}
        if (max_idx == 1 or max_idx == 2 or max_idx == 3 or max_idx == 4)
          # console.log "snare"
          note = {pitch: 2, vel: Math.min(sum, 110), len: 4}
        if (results[0] < 2) and (max_idx > 3)
          # console.log "hat"
          note = {pitch: 3, vel: Math.min(sum, 110), len: 4}
      pitches.push(note)
    pitches

  merge: (notes) ->
    sus = {pitch: 0}
    for note, i in notes
      next = notes[i+1] || {pitch: 0}
      dnext = notes[i+2] || {pitch: 0}

      # Fix onset and ending errors.
      if note.pitch != sus.pitch and (next.pitch == dnext.pitch or dnext.pitch == 0)
        if Math.abs(note.pitch - next.pitch) == 1
          console.log("onset error")
          note.pitch = next.pitch
      if note.pitch != next.pitch and sus.len > 1
        if Math.abs(note.pitch - sus.pitch) == 1
          console.log("ending error")
          note.pitch = 0
          sus.len++

      # Fix runner errors, like A-Bb-B all in a row quickly.
      if (note.pitch == next.pitch + 1 == dnext.pitch + 2) or (note.pitch == next.pitch - 1 == dnext.pitch - 2)
        if (sus.pitch != note.pitch) && (!notes[i+3] or notes[i+3].pitch == 0) #Escape for chromatic scale.
          console.log("runner error")
          note.pitch = next.pitch
          dnext.pitch = next.pitch

      # Fix octave errors.
      while sus.pitch != 0 and next.pitch != 0 and note.pitch > sus.pitch + 7 and note.pitch > next.pitch + 7
        console.log("octave error")
        note.pitch /= 2

      # Merge notes
      if sus and sus.pitch == note.pitch
        note.pitch = 0
        sus.len++
      else
        sus = note

    return notes


  mergeDrums: (notes) ->
    for note, i in notes
      prev = notes[i-1]
      if prev and prev.pitch == note.pitch
        note.pitch = 0
        note.vel = 0
        # threshold = if note.pitch == 2 then 2 else 5/4
        # if prev.vel > threshold*note.vel
        #   note.pitch = 0
        #   note.vel = 0
        # else if prev.vel*threshold < note.vel
        #   prev.pitch = 0
        #   prev.vel = 0
    notes


  standardize: (notes, tempo, minInterval) ->
    # Deal with latency
    notes = notes.slice(Math.round(240/tempo))
    # Lol guys check out this hack:
    onBeatCount = 0
    offBeatCount = 0
    for note, i in notes
      if note.pitch
        if (i % 2) # offbeat notes
          offBeatCount++
        else
          onBeatCount++

    if offBeatCount > onBeatCount then notes = notes.slice(1)

    len = notes.length
    nextPowerOf2 = @nextPowerOf2(len)
    prevPowerOf2 = nextPowerOf2/2

    if (len - prevPowerOf2) < minInterval
      notes = notes.slice(0, prevPowerOf2)
    else
      while (notes.length < nextPowerOf2)
        notes.push({pitch:0, vel: 0, len: 1})


    notes

  convertToDrums: (buffer, tempo, minInterval) ->
    chunks = @chunk(buffer, tempo, minInterval, 1)
    drumPitches = @convertToDrumPitches(chunks)
    merged = @mergeDrums(drumPitches)
    stdzd = @standardize(merged, tempo, minInterval)
    return stdzd

  convertToNotes: (buffer, tempo, minInterval) ->
    chunks = @chunk(buffer, tempo, minInterval, 2) # 3 is the chunking factor
    console.log "chunks", chunks
    pitches = @convertToPitches(chunks, 2)
    console.log "pitches", pitches
    merged = @merge(pitches)
    console.log "merged", merged
    stdzd = @standardize(merged, tempo, minInterval)
    console.log "stdzd", stdzd
    return stdzd

  nextPowerOf2: (n) ->
    n--
    n |= n >> 1
    n |= n >> 2
    n |= n >> 4
    n |= n >> 8
    n |= n >> 16
    ++n