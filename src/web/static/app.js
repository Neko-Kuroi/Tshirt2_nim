// 数量入力の ＋/－ ボタン
document.querySelectorAll(".qty-step").forEach(function (box) {
  var input = box.querySelector("input");
  box.querySelectorAll("[data-step]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var n = parseInt(input.value || "0", 10) || 0;
      var next = n + parseInt(btn.dataset.step, 10);
      var min = input.dataset.allowNegative === "1" ? -999999 : 0;
      input.value = Math.max(min, next);
    });
  });
});

// 入荷画面: 選んだ品番のカテゴリー設定に合わせて入力欄を出し分ける
var itemSel = document.getElementById("item_id");
if (itemSel) {
  var update = function () {
    var opt = itemSel.options[itemSel.selectedIndex];
    ["color", "size", "variant_name"].forEach(function (f) {
      var wrap = document.getElementById("f_" + f);
      if (!wrap) return;
      var on = opt && opt.dataset["uses" + f.replace(/(^|_)(\w)/g, function (_, __, c) { return c.toUpperCase(); })] === "1";
      wrap.hidden = !on;
      wrap.querySelectorAll("input").forEach(function (i) { i.disabled = !on; });
    });
  };
  itemSel.addEventListener("change", update);
  update();
}
