local H = {}

function H.eq(a, b, msg)
  if a ~= b then error(("%s: expected %s, got %s"):format(msg or "eq", tostring(b), tostring(a)), 2) end
end

function H.near(a, b, tol, msg)
  if type(a) ~= "number" or math.abs(a - b) > tol then
    error(("%s: expected %.6g ± %.3g, got %s"):format(msg or "near", b, tol, tostring(a)), 2)
  end
end

function H.truthy(v, msg)
  if not v then error(msg or "expected truthy", 2) end
end

return H
