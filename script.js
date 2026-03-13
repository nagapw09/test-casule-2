const counterButton = document.getElementById("counterButton");
const backendButton = document.getElementById("backendButton");
const backendResult = document.getElementById("backendResult");
let clickCount = 0;

if (counterButton) {
  counterButton.addEventListener("click", () => {
    clickCount += 1;
    counterButton.textContent = `Нажато: ${clickCount}`;
  });
}

if (backendButton && backendResult) {
  backendButton.addEventListener("click", async () => {
    backendResult.textContent = "Запрашиваю...";

    try {
      const response = await fetch("/api/hello");

      if (!response.ok) {
        throw new Error(`Ошибка: ${response.status}`);
      }

      const data = await response.json();
      backendResult.textContent = `${data.message} (время: ${data.time})`;
    } catch (error) {
      backendResult.textContent = "Не удалось получить ответ от сервера.";
      console.error(error);
    }
  });
}
