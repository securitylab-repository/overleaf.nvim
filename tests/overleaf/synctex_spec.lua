local synctex = require('overleaf.synctex')

describe('synctex', function()
  describe('_highlight_range', function()
    local lines = { 'a', 'b', '', 'c', 'd', 'e', '  ', 'f' }

    it('selects the paragraph around the cursor', function()
      local first, last = synctex._highlight_range(lines, 5, 'paragraph')
      assert.are.same({ 4, 6 }, { first, last })
    end)

    it('stops at the file edges', function()
      assert.are.same({ 1, 2 }, { synctex._highlight_range(lines, 1, 'paragraph') })
      assert.are.same({ 8, 8 }, { synctex._highlight_range(lines, 8, 'paragraph') })
    end)

    it('does not widen a blank cursor line', function()
      assert.are.same({ 3, 3 }, { synctex._highlight_range(lines, 3, 'paragraph') })
    end)

    it('caps a paragraph that has no blank line', function()
      local long = {}
      for i = 1, 500 do
        long[i] = 'x'
      end
      assert.are.same({ 160, 240 }, { synctex._highlight_range(long, 200, 'paragraph') })
    end)

    it('takes N lines each way and clamps to the file', function()
      assert.are.same({ 3, 7 }, { synctex._highlight_range(lines, 5, 2) })
      assert.are.same({ 1, 3 }, { synctex._highlight_range(lines, 1, 2) })
      assert.are.same({ 5, 5 }, { synctex._highlight_range(lines, 5, 0) })
    end)
  end)

  describe('_union_hits', function()
    it('covers every box on the page', function()
      local box = synctex._union_hits({
        { page = 2, h = 100, v = 200, width = 300, height = 10 },
        { page = 2, h = 110, v = 260, width = 280, height = 10 },
      }, 2)
      assert.are.same({ page = 2, h = 100, v = 260, width = 300, height = 70 }, box)
    end)

    it('ignores boxes on other pages and unusable ones', function()
      local box = synctex._union_hits({
        { page = 1, h = 0, v = 900, width = 500, height = 10 },
        { page = 2, h = 100, v = 200, width = 300, height = 10 },
        { page = 2, h = 100, v = 250 },
      }, 2)
      assert.are.same({ page = 2, h = 100, v = 200, width = 300, height = 10 }, box)
      assert.is_nil(synctex._union_hits({ { page = 1, h = 0, v = 9, width = 5, height = 5 } }, 2))
    end)
  end)

  describe('_probe', function()
    it('stops at the first line that maps to a box', function()
      local asked = {}
      local sync_code = function(l, _, cb)
        table.insert(asked, l)
        cb(nil, { pdf = l == 12 and { { page = 1 } } or {} })
      end
      local got
      synctex._probe(sync_code, { 10, 11, 12, 13 }, function(pdf) got = pdf end)
      assert.are.same({ 10, 11, 12 }, asked)
      assert.are.same({ { page = 1 } }, got)
    end)

    it('gives up with an empty list, treating errors as no match', function()
      local sync_code = function(_, _, cb) cb({ message = 'boom' }) end
      local got
      synctex._probe(sync_code, { 1, 2, 3 }, function(pdf) got = pdf end)
      assert.are.same({}, got)
    end)

    it('tries a bounded number of lines', function()
      local n = 0
      local sync_code = function(_, _, cb)
        n = n + 1
        cb(nil, { pdf = {} })
      end
      local candidates = {}
      for i = 1, 50 do
        candidates[i] = i
      end
      synctex._probe(sync_code, candidates, function() end)
      assert.are.equal(6, n)
    end)
  end)

  describe('_highlight_synctex', function()
    local hit = { page = 3, h = 100, v = 200, width = 50, height = 10 }

    it('puts the box on the requested page', function()
      local content = synctex._highlight_synctex(hit)
      assert.is_truthy(content:find('\n{3\n', 1, true))
      assert.is_truthy(content:find('\n}3\n', 1, true))
    end)

    it('converts the box from PDF points to scaled points', function()
      local content = synctex._highlight_synctex(hit)
      -- 1 bp = 65536 * 72.27 / 72 sp
      local sp = function(bp) return string.format('%.0f', bp * 65536 * 72.27 / 72) end
      local record = string.format('(1,1:%s,%s:%s,%s,0', sp(100), sp(200), sp(50), sp(10))
      assert.is_truthy(content:find(record, 1, true))
    end)

    it('references the placeholder source used by -forward-search', function()
      local content = synctex._highlight_synctex(hit)
      assert.is_truthy(content:find('Input:1:overleaf-forward-search.tex', 1, true))
    end)

    it('uses plain newlines only', function()
      assert.is_nil(synctex._highlight_synctex(hit):find('\r'))
    end)

    it('returns nil when the box has no usable size', function()
      assert.is_nil(synctex._highlight_synctex({ page = 1, h = 1, v = 1 }))
      assert.is_nil(synctex._highlight_synctex({ page = 1, h = 1, v = 1, width = 0, height = 5 }))
      assert.is_nil(synctex._highlight_synctex({ page = 0, h = 1, v = 1, width = 5, height = 5 }))
    end)
  end)
end)
