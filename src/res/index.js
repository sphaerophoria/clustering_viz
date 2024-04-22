window.onload = async function () {
  const response = await fetch("/points");
  const points = await response.json();

  /** @type HTMLCanvasElement */
  const canvas = document.getElementById("canvas");
  const ctx = canvas.getContext("2d");

  const canvas_scale = 7;
  const canvas_offset = 25;

  for (const point of points) {
    ctx.beginPath();
    ctx.arc(
      point.x * canvas_scale + canvas_offset,
      point.y * canvas_scale + canvas_offset,
      10,
      0,
      2 * Math.PI,
    );
    ctx.fillStyle = "red";
    ctx.fill();
  }
};
