# Refactoring status: 70%
{Point, Range} = require 'atom'
_    = require 'underscore-plus'
Base = require './base'

class TextObject extends Base
  @extend()
  complete: true
  recodable: false

  rangeToBeginningOfFile: (point) ->
    new Range(Point.ZERO, point)

  rangeToEndOfFile: (point) ->
    new Range(point, Point.INFINITY)

# Word
# -------------------------
# [FIXME] Need to be extendable.
class Word extends TextObject
  @extend()
  select: ->
    for selection in @editor.getSelections()
      wordRegex = @wordRegExp ? selection.cursor.wordRegExp()
      @selectExclusive(selection, wordRegex)
      @selectInclusive(selection) if @inclusive
      not selection.isEmpty()

  selectExclusive: (selection, wordRegex) ->
    range = selection.cursor.getCurrentWordBufferRange({wordRegex})
    selection.setBufferRange(range)

  selectInclusive: (selection) ->
    scanRange = selection.cursor.getCurrentLineBufferRange()
    headPoint = selection.getHeadBufferPosition()
    scanRange.start = headPoint
    @editor.scanInBufferRange /\s+/, scanRange, ({range, stop}) ->
      if headPoint.isEqual(range.start)
        selection.selectToBufferPosition range.end
        stop()

class WholeWord extends Word
  @extend()
  wordRegExp: /\S+/

# Pair
# -------------------------
class Pair extends TextObject
  @extend()
  inclusive: false
  pair: null

  isStartingPair:(str, char) ->
    pattern = ///[^\\]?#{_.escapeRegExp(char)}///
    count = str.split(pattern).length - 1
    (count % 2) is 1

  needStopSearch: (pair, cursorRow, row) ->
    pair not in ["{}", "[]", "()"] and (cursorRow isnt row)

  findPair: (cursorPoint, fromPoint, pair, backward=false) ->
    pairChars = pair.split('')
    pairChars.reverse() unless backward
    [search, searchPair] = pairChars
    pairRegexp = pairChars.map(_.escapeRegExp).join('|')
    pattern   = ///(?:#{pairRegexp})///g

    [scanFunc, scanRange] =
      if backward
        ['backwardsScanInBufferRange', @rangeToBeginningOfFile(fromPoint)]
      else
        ['scanInBufferRange', @rangeToEndOfFile(fromPoint)]

    nest = 0
    found = null # We will search to fill this var.

    @editor[scanFunc] pattern, scanRange, ({matchText, range, stop}) =>
      charPre = @editor.getTextInBufferRange(range.traverse([0, -1], [0, -1]))
      return if charPre is '\\' # Skip escaped char with '\'

      # don't search across line unless specific pair.
      if @needStopSearch(pair, cursorPoint.row, range.start.row)
        return stop()

      if search is searchPair
        if backward
          text = @editor.lineTextForBufferRow(fromPoint.row)
          if @isStartingPair(text[0..range.end.column], search)
            found = range
        else
          # skip for pair not within cursorPoint.
          if range.end.isLessThan(cursorPoint)
            stop()
          else
            found = range
      else
        lastChar = matchText[matchText.length-1]
        switch lastChar
          when search
            if (nest is 0) then found = range else nest--
          when searchPair
            nest++
      stop() if found
    if found? then found.end else null

  getRange: (selection, pair) ->
    if originallyEmpty = selection.isEmpty()
      selection.selectRight()
    point = selection.getHeadBufferPosition()
    start  = @findPair(point, point, pair, true)
    range = null
    if start? and (end = @findPair(point, start, pair)?.traverse([0, -1]))
      range = new Range(start, end)
      range = range.translate([0, -1], [0, 1]) if @inclusive
    unless range and originallyEmpty
      selection.selectLeft()
    range

  select: ->
    for selection in @editor.getSelections()
      if range = @getRange(selection, @pair)
        selection.setBufferRange(range)
      not selection.isEmpty()

class AnyPair extends Pair
  @extend()
  pairs: ['""', "''", "``", "{}", "<>", "><", "[]", "()"]

  select: ->
    for selection in @editor.getSelections()
      ranges = []
      for pair in @pairs when (range = @getRange(selection, pair))
        ranges.push range
      unless _.isEmpty(ranges)
        ranges = ranges.sort (a, b) -> a.compare(b)
        selection.setBufferRange(_.last(ranges))
      not selection.isEmpty()

class DoubleQuotes extends Pair
  @extend()
  pair: '""'

class SingleQuotes extends Pair
  @extend()
  pair: "''"

class BackTicks extends Pair
  @extend()
  pair: '``'

class CurlyBrackets extends Pair
  @extend()
  pair: '{}'

class AngleBrackets extends Pair
  @extend()
  pair: '<>'

# [FIXME] See #795
class Tags extends Pair
  @extend()
  pair: '><'

class SquareBrackets extends Pair
  @extend()
  pair: '[]'

class Parentheses extends Pair
  @extend()
  pair: '()'

# Paragraph
# -------------------------
# In Vim world Paragraph is defined as consecutive (non-)blank-line.
class Paragraph extends TextObject
  @extend()
  linewise: false

  isLinewise: ->
    @linewise

  getStartRow: (startRow, fn) ->
    for row in [startRow..0] when fn(row)
      return row+1
    0

  getEndRow: (startRow, fn) ->
    lastRow = @editor.getLastBufferRow()
    for row in [startRow..lastRow] when fn(row)
      return row
    lastRow+1

  getRange: (startRow) ->
    startRowIsBlank = @editor.isBufferRowBlank(startRow)
    fn = (row) =>
      @editor.isBufferRowBlank(row) isnt startRowIsBlank
    new Range([@getStartRow(startRow, fn), 0], [@getEndRow(startRow, fn), 0])

  selectParagraph: (selection) ->
    [startRow, endRow] = selection.getBufferRowRange()
    if startRow is endRow
      @linewise = true
      if range = @getRange(startRow)
        selection.setBufferRange(range)
    else # have direction
      if selection.isReversed()
        if range = @getRange(startRow-1)
          selection.selectToBufferPosition range.start
      else
        if range = @getRange(endRow+1)
          selection.selectToBufferPosition range.end

  selectExclusive: (selection) ->
    @selectParagraph(selection)

  selectInclusive: (selection) ->
    @selectParagraph(selection)
    @selectParagraph(selection)

  select: ->
    results = []
    for selection in @editor.getSelections()
      _.times @getCount(1), =>
        if @inclusive
          @selectInclusive(selection)
        else
          @selectExclusive(selection)
      results.push not selection.isEmpty()
    if @isLinewise() and @vimState.isMode('visual', ['characterwise', 'blockwise'])
      @vimState.activateVisualMode('linewise')
    results

class Comment extends Paragraph
  @extend()
  selectInclusive: (selection) ->
    @selectParagraph(selection)

  getRange: (startRow) ->
    return unless @editor.isBufferRowCommented(startRow)
    fn = (row) =>
      return if (@inclusive and @editor.isBufferRowBlank(row))
      @editor.isBufferRowCommented(row) in [false, undefined]
    new Range([@getStartRow(startRow, fn), 0], [@getEndRow(startRow, fn), 0])

class Indentation extends Paragraph
  @extend()
  selectInclusive: (selection) ->
    @selectParagraph(selection)

  getRange: (startRow) ->
    return if @editor.isBufferRowBlank(startRow)
    text = @editor.lineTextForBufferRow(startRow)
    baseIndentLevel = @editor.indentLevelForLine(text)
    fn = (row) =>
      if @editor.isBufferRowBlank(row)
        not @inclusive
      else
        text = @editor.lineTextForBufferRow(row)
        @editor.indentLevelForLine(text) < baseIndentLevel
    new Range([@getStartRow(startRow, fn), 0], [@getEndRow(startRow, fn), 0])

class CurrentLine extends TextObject
  @extend()
  select: ->
    for selection in @editor.getSelections()
      selection.cursor.moveToBeginningOfLine()
      unless @inclusive
        selection.cursor.moveToFirstCharacterOfLine()
      selection.selectToEndOfLine()
      not selection.isEmpty()

class Entire extends TextObject
  @extend()
  select: ->
    @editor.selectAll()
    not s.isEmpty() for s in @editor.getSelections()

module.exports = {
  Word, WholeWord,
  DoubleQuotes, SingleQuotes, BackTicks, CurlyBrackets , AngleBrackets, Tags,
  SquareBrackets, Parentheses,
  AnyPair
  Paragraph, Comment, Indentation,
  CurrentLine, Entire,
}
